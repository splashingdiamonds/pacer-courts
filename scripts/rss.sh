#!/bin/bash

function echo_debug () {
  [[ -n "$DEBUG" ]] && \
    echo "${@}" | \
    sed 's/^/[DEBUG]\t/';
}

function echo_notice () {
  [[ -n "$DEBUG" || -n "$NOTICE" ]] && \
    echo "${@}" | \
    sed 's/^/[NOTICE]\t/';
}

function graceful () {
  grace=$(shift)
  `${grace}` ${@} >/dev/null 2>&1
}

date_fetched="$(date -u)"
date_saved="$(date -u)"

echo_debug $'\n\n=== ENVIRONMENT ==='
for line in `env`; do echo_debug "${line}" ; done
echo_debug $'===================\n\n'

echo_debug $'Date started:\t'$date_fetched
echo_debug $'Environment:\tCI='$CI

mkdir -p {temp,latest,artifacts}/{rss,pages}/
mkdir -p temp/{rss,pages}/
mkdir -p latest/{rss,pages}/

function fetch {
  local src_url="$1";
  local dest_fn="$2";
  echo_debug $'\n\n';
  echo_debug $'fetched URL:\t\t'$src_url;
  echo_debug $'local saved copy:\t\t'$dest_fn;
  mkdir -p $(dirname "$dest_fn");
  curl "$src_url" \
    --no-progress-bar \
    --location \
    --silent \
    --dump-header "$dest_fn.headers" \
    --connect-timeout 10 \
    --output "$dest_fn";
}

function fetch_rss {
  local login_hostname="$1"
  local dest_slug="$(echo "$login_hostname" | sed -e 's/\.uscourts\.gov//g')" 

  graceful git checkout artifacts/
  graceful git checkout latest/
  git clean -fd

  web_url="$(grep "$login_hostname" courts.json -B 2 -A 2 | grep '"web_url":' | cut -d '"' -f 4)";
  echo_debug $'\n\n----------\n'
  echo_debug $'login url:\t' $login_hostname;
  echo_debug $'web url:\t' $web_url;
  [[ ! "$web_url" = "" ]] && fetch "$web_url" "artifacts/pages/${dest_slug}/www.html";
  [[ "$web_url" = "" ]] && touch "artifacts/pages/${dest_slug}/www.html.missing";
  echo_debug $'\n----------\n\n'

  fetch "https://$login_hostname" "artifacts/pages/${dest_slug}/ecf.html";

  rss_feed_format_1="https://$login_hostname/cgi-bin/rss_outside.pl";
  rss_feed_format_2="https://$login_hostname/n/beam/servlet/TransportRoom?servlet=RSSGenerator";

  fetch "$rss_feed_format_1" "artifacts/rss/${dest_slug}/rss-format-1.xml";
  fetch "$rss_feed_format_2" "artifacts/rss/${dest_slug}/rss-format-2.xml";

  mkdir -p "artifacts/rss/$dest_slug/raw"
  status="$(grep -ri '200 OK' "artifacts/rss/$dest_slug/" --files-with-matches | grep '\.headers')"
  latest_valid_rss=""
  if [[ ! "$status" = "" ]]; then
    latest_valid_rss="${status%.*}"
    
    transform_rss () {
      input_path=$1;
      output_path=$2;

      rss_basename="$(basename $1)"
      rss_url=""
      if [[ "$rss_basename" =~ "rss-format-1.xml" ]]; then
        echo_debug $'Detected URL format 1 (from Status of HTTP response):\n\t(200 STATUS OK)\t'$(echo $status | sed -e 's/\.headers$//')
        rss_url=$rss_feed_format_1;
      elif [[ "$rss_basename" =~ "rss-format-2.xml" ]]; then
        echo_debug $'Detect URL format 2 (from Status of HTTP response):\n\t(200 STATUS OK)\t\t'$(echo $status | sed -e 's/\.headers$//')
        rss_url=$rss_feed_format_2;
      fi
      echo_debug $'\nRSS URL:\t'$rss_url$'\n';

      cat "$input_path" > "$output_path";

      cat "$output_path" > "artifacts/rss/${dest_slug}.rss.xml"

      rss_url_escaped="$(echo $rss_url | sed -e 's#/#\\/#g')"

      cat "$1" |
        sed -E 's/<rss(.*)/<rss\1 \n    xmlns:atom="http:\/\/www.w3.org\/2005\/Atom"/' | \
        sed -E "s/<channel(.*)>/<channel\1>\n\n    <atom:link href=\"$rss_url_escaped\" rel=\"self\" type=\"application\/rss+xml\" \/>\n/g" | \
        sed -E 's/[[:blank:]]*$//g'  > "temp/rss/${dest_slug}.modified.rss.xml";
    }

    transform_rss "./$latest_valid_rss" "temp/rss/${dest_slug}.rss.modified.xml"

    cat "temp/rss/${dest_slug}.modified.rss.xml" > "artifacts/rss/${dest_slug}.rss.xml"

    cat "artifacts/rss/${dest_slug}.rss.xml" > "latest/rss/${dest_slug}.rss.xml"

    if [ -f "$PWD/latest/rss/$dest_slug.rss.xml.missing" ]; then
      git rm $latest_valid_rss "latest/rss/$dest_slug.rss.xml.missing" --silent;
    fi

    cat "artifacts/rss/${dest_slug}.rss.xml" > "latest/rss/${dest_slug}.rss.xml"
  else
    if [ ! -f "$PWD/latest/rss/$dest_slug.rss.xml.missing" ]; then
      touch "latest/rss/$dest_slug.rss.xml.missing";
    fi
  fi
  date_saved="$(date -u)"

  force_commit="true"


  # Commit '.missing' files. Examples:
  # - latest/ecf.wvsd.rss.xml.missing
  git ls-files --modified --deleted --others | grep -q '\.missing$' && force_commit="true"

  # Commit any additions or modifications to the downloaded HTML documents
  # of the court login & root web pages. Examples:
  # - artifacts/pages/ecf.almb/ecf.html
  #   (downloaded from ecf.almb.uscourts.gov -- the court's log-in page / root page on hostname)
  # - artifacts/pages/ecf.almb/www.html
  #   (downloaded from www.ecf.almb.uscourts.gov -- the court's public entry-point page)
  git ls-files --modified --deleted --others | grep -q '\.html$' && force_commit="true"

  # Commit newly created files. Examples:
  # - artifacts/pages/www.html
  git ls-files --others | grep -q -v '^temp/' && force_commit="true"

  # The number of lines changed in the RSS feed. Examples:
  #  0: The remote file is up to date with (identical to) the saved file tracked in this repository.
  #  1: The `lastBuildDate` timestamp in the RSS feed changed, but no new items were added/changed.
  # 2+: The `lastBuildDate` timestamp changed, and new <item>s were found in the <channel>'s RSS feed.
  rss_diff_lines_changed="$(git diff -- "latest/rss/${dest_slug}.rss.xml" | grep '@@' | wc -l)"
  if [[ "$rss_diff_lines_changed" -lt 2 ]]; then
    git ls-files --modified --deleted --others | \
      grep -q "latest/rss/${dest_slug}.rss.xml" && \
        force_commit="false"
  fi

  if [[ "$force_commit" == "false" ]]; then
    echo_notice 'RSS <lastBuildDate> changed but <channel> <item>s remain unchanged. (Skipping git commit and push.)';
    graceful git checkout artifacts/rss/${dest_slug}/
    graceful git checkout latest/rss/${dest_slug}/
    graceful git checkout "latest/rss/${dest_slug}.rss.xml";

    # graceful git checkout "artifacts/pages/${dest_slug}/ecf.html.headers";
    # graceful git checkout "artifacts/pages/${dest_slug}/www.html.headers";
    # graceful git checkout "artifacts/rss/${dest_slug}/rss-format-1.xml";
    # graceful git checkout "artifacts/rss/${dest_slug}/rss-format-2.xml";
    # graceful git checkout "artifacts/rss/${dest_slug}/rss-format-1.xml.headers";
    # graceful git checkout "artifacts/rss/${dest_slug}/rss-format-2.xml.headers";
    # graceful git checkout "artifacts/rss/${dest_slug}.rss.xml"
    # graceful git checkout "latest/rss/${dest_slug}.rss.xml";
  else
    git add -A

    commit_msg="Update ${dest_slug} court feeds and pages.${commit_msg_suffix}"

    git commit -m "$commit_msg";

    if [[ ! -f "latest/rss/${dest_slug}.rss.xml" ]]; then
      touch $latest_valid_rss "latest/rss/$dest_slug.rss.xml.missing"
      git add "latest/rss/$dest_slug.rss.xml.missing";
      commit_msg="Missing ${dest_slug} court feed.${commit_msg_suffix}"
      git commit -m "$commit_msg";
    fi

    if [[ -n "$CI" ]]; then
      git push || true;
    fi
  fi
}

commit_msg_suffix=`printf $'\n\t\nLast Updated:\t%s\nFetched:\t%s\nSaved:\t%s\n' "$date_source_last_updated" "$date_fetched" "$date_saved"`

# For each court's hostname:
# Fetch, check, commit changes from every RSS feed (on either of the two URL permutations).
for court_id in `cat courts.json | grep '"login_url":' | cut -d '/' -f3 | tr -d "," | tr -d '"' | sort -u | sed -e 's/www\.//g' | sort -u | cut -d '.' -f 1- | sort -u | grep -v "pcl\.uscourts\.gov"`; do
  court_html_origin="$(echo $court_id | tr -d '"')"
  echo_debug $'\n\nCOURT HTML ORIGIN:\t'$court_html_origin$'\n'
  fetch_rss "$court_html_origin" || true
  if [[ -n "$CI" ]]; then
    git push || true;
  fi
done

