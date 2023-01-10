#!/bin/bash

# set -e -o xtrace

DEBUG="1"

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
# for line in `env`; do echo_debug "${line}" ; done
echo_debug $'===================\n\n'

echo_debug $'Date started:\t'$date_fetched
echo_debug $'Environment:\tCI='$CI

mkdir -p {temp,latest,artifacts}/{rss,pages}/
mkdir -p temp/{artifacts,latest}/{rss,pages}/
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

function transform_rss {
  local dest_slug="$1";
  local input_path="$2";
  local response_status="$3";

  local artifacts_rss_fn="artifacts/rss/${dest_slug}.rss.xml";
  local latest_rss_fn="latest/rss/${dest_slug}.rss.xml";

  local rss_basename="$(basename $artifacts_rss_fn)";
  local rss_url="";

  if [[ "$rss_basename" =~ "rss-format-1.xml" ]]; then
    echo_debug $'Detected URL format 1 (from Status of HTTP response):\n\t(200 STATUS OK)\t'$(echo $response_status | sed -e 's/\.headers$//')
    rss_url=$rss_feed_format_1;
  elif [[ "$rss_basename" =~ "rss-format-2.xml" ]]; then
    echo_debug $'Detect URL format 2 (from Status of HTTP response):\n\t(200 STATUS OK)\t\t'$(echo $response_status | sed -e 's/\.headers$//')
    rss_url=$rss_feed_format_2;
  fi

  if [[ -f "$artifacts_rss_fn" && ! "$rss_basename" = "" ]]; then

    echo_debug $'\nRSS URL:\t'$rss_url$'\n';

    touch "$artifacts_rss_fn";
    cat "$input_path" > "$artifacts_rss_fn";

    local rss_url_escaped="$(echo $rss_url | sed -e 's#/#\\/#g')";

    mkdir -p `dirname "temp/$input_path"`;

    cat "$input_path" | \
      sed -E 's/<rss(.*)/<rss\1 \n    xmlns:atom="http:\/\/www.w3.org\/2005\/Atom"/' | \
      sed -E "s/<channel(.*)>/<channel\1>\n\n    <atom:link href=\"$rss_url_escaped\" rel=\"self\" type=\"application\/rss+xml\" \/>\n/g" | \
      sed -E 's/[[:blank:]]*$//g' > "temp/$input_path";

    bash ./scripts/xml_format.sh "temp/$input_path";

    cat "temp/$input_path";
  fi
}

function git_diff_modified_lines_raw {
  git diff --unified=0 -- "$1" | tail +5 | grep -v '@@' | grep '^\+'
}

function git_diff_modified_lines_count {
  git diff --unified=0 -- "$1" || grep '@@' | wc -l | bc
}

function fetch_rss {
  local login_hostname="$1"
  local dest_slug="$(echo "$login_hostname" | sed -e 's/\.uscourts\.gov//g')" 

  graceful git checkout artifacts/
  graceful git checkout latest/
  # git clean -fd -X -i

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

  # TODO: Use the correct version.
  # Choose RSS file over 404 HTML/no response.
  fetch "$rss_feed_format_1" "artifacts/rss/${dest_slug}/rss-format-1.xml";
  fetch "$rss_feed_format_2" "artifacts/rss/${dest_slug}/rss-format-2.xml";

  force_commit="false"

  # Whichever
  mkdir -p "artifacts/rss/$dest_slug";
  response_status="$(grep -ri '200 OK' "artifacts/rss/$dest_slug/" --files-with-matches | grep -q '\.headers')"
  latest_rss_fn=""
  if [[ ! "$response_status" = "" ]]; then
    latest_rss_fn="${response_status%.*}";

    `transform_rss "$dest_slug" "$latest_rss_fn" "$response_status"` > "temp/rss/${dest_slug}.rss.transformed.xml" ;

    artifacts_rss_fn="artifacts/rss/${dest_slug}.rss.xml";
    latest_rss_fn="latest/rss/${dest_slug}.rss.xml";

    rss_basename="$(basename $artifacts_rss_fn)";

    mkdir -p "$rss_basename";

    touch "$artifacts_rss_fn";
    cat "temp/rss/${dest_slug}.rss.transformed.xml" > "$artifacts_rss_fn";

    cat "$artifacts_rss_fn" > "$latest_rss_fn";

    if [ -f "$PWD/latest/rss/$dest_slug.rss.xml.missing" ]; then
      git rm "latest/rss/$dest_slug.rss.xml.missing" --quiet;
    fi
    touch "$latest_rss_fn";
    cat "$artifacts_rss_fn" > "$latest_rss_fn";
  else
    if [ ! -f "$PWD/latest/rss/$dest_slug.rss.xml.missing" ]; then
      touch "latest/rss/$dest_slug.rss.xml.missing";
      force_commit="true"
    fi
  fi

  date_saved="$(date -u)"

  # TODO: Consider ignoring some noisy changes, such as Date, Expires, Set-Cookie, Cookie headers:
  # git diff --unified=0 artifacts/pages/ecf.njb/ecf.html.headers | \
  #   sed -e 's/[\+-]Date:.*//g' | \
  #   sed -e 's/[\+-]Expires:.*//g' | \
  #   sed -e 's/[\+-]Set-Cookie.*//g' | \
  #   sed -e 's/[\+-]Cookie.*//g'

  # Commit '.missing' files. Examples:
  # - latest/ecf.wvsd.rss.xml.missing
  git ls-files --modified --deleted --others | grep -q '\.missing$' && force_commit="true"

  # Commit any additions or modifications to the downloaded HTML documents
  # of the court login & root web pages. Examples:
  # - artifacts/pages/ecf.almb/ecf.html
  #   (downloaded from ecf.almb.uscourts.gov -- the court's log-in page / root page on hostname)
  # - artifacts/pages/ecf.almb/www.html
  #   (downloaded from www.ecf.almb.uscourts.gov -- the court's public entry-point page)
  # git ls-files --modified --deleted --others | grep -q '\.html$' && force_commit="true"

  # Commit newly created files. Examples:
  # - artifacts/pages/www.html
  for file in `git ls-files --modified --deleted --others | grep -q -v '^temp/'`; do
    diff_lines_changed=`git_diff_modified_lines_count "$file"`
    echo_debug '$file' $'\t' 'Lines changed count:'$diff_lines_changed

    # If three or more lines changed, then consider the changes worth committing.
    if [[ $diff_lines_changed -gt 3 ]]; then
      force_commit="true"
    fi
  done

  # The number of lines changed in the RSS feed. Examples:
  #  0: The remote file is up to date with (identical to) the saved file tracked in this repository.
  #  1: The `lastBuildDate` timestamp in the RSS feed changed, but no new items were added/changed.
  # 2+: The `lastBuildDate` timestamp changed, and new <item>s were found in the <channel>'s RSS feed.

  rss_diff_lines_changed=`git_diff_modified_lines_count "$latest_rss_fn"`
  echo 'Lines modified:'$rss_diff_lines_changed

  echo_debug "$latest_rss_fn" $'\t' 'Lines modified:'$diff_lines_changed

  rss_diff_other_lines_changed="$(git_diff_modified_lines_raw $latest_rss_fn && grep -i -q "lastBuildDate" | wc -l | bc)"
  if [[ $rss_diff_lines_changed -eq 1 && $rss_diff_other_lines_changed -gt 0 ]]; then
    echo_notice 'RSS <lastBuildDate> changed but <channel> <item>s remain unchanged. (Skipping git commit and push.)';
  fi

  linecount_besides_timestamp=$(git_diff_modified_lines_raw $latest_rss_fn | grep -v -q "lastBuildDate" | wc -l | bc)
  if [[ $linecount_besides_timestamp -gt 1 ]]; then
    force_commit="true"
    echo_debug 'RSS <lastBuildDate> changed but <channel> <item>s remain unchanged. (Skipping git commit and push.)';
  fi

  if [[ "$force_commit" == "false" ]]; then
    graceful git checkout "artifacts/pages/${dest_slug}/ecf.html";
    graceful git checkout "artifacts/pages/${dest_slug}/ecf.html";
    graceful git checkout "artifacts/pages/${dest_slug}/www.html.headers";
    graceful git checkout "artifacts/pages/${dest_slug}/www.html.headers";
    graceful git checkout "$artifacts_rss_fn";
    graceful git checkout "artifacts/rss/${dest_slug}/rss-format-1.xml.headers";
    graceful git checkout "artifacts/rss/${dest_slug}/rss-format-1.xml";
    graceful git checkout "artifacts/rss/${dest_slug}/rss-format-2.xml.headers";
    graceful git checkout "artifacts/rss/${dest_slug}/rss-format-2.xml";
    graceful git checkout "$latest_rss_fn";
  else
    git add -A

    commit_msg="Update ${dest_slug} court feeds and pages.${commit_msg_suffix}"

    git commit -m "$commit_msg";

    if [[ ! -f "$latest_rss_fn" ]]; then
      touch $latest_rss_fn "latest/rss/$dest_slug.rss.xml.missing"
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
for court_id in `cat courts.json | grep '"login_url":' | cut -d '/' -f3 | tr -d "," | tr -d '"' | sort -u | sed -e 's/www\.//g' | sort -u | cut -d '.' -f 1- | sort -u | grep -v "pcl\.uscourts\.gov"| grep "njb\.uscourts\.gov"`; do
  court_html_origin="$(echo $court_id | tr -d '"')"
  echo_debug $'\n\nCOURT HTML ORIGIN:\t'$court_html_origin$'\n'
  fetch_rss "$court_html_origin" || true
  if [[ -n "$CI" ]]; then
    git push || true;
  fi
done
