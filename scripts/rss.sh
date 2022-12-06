#!/bin/bash

date_fetched="$(date -u)"
date_saved="$(date -u)"

mkdir -p {temp,latest,artifacts}/{rss,pages}/
mkdir -p temp/{rss,pages}/
mkdir -p latest/{rss,pages}/

function fetch {
  local src_url="$1";
  local dest_fn="$2";
  # echo $'\n\n';
  # echo $src_url;
  echo $'\n\n'
  echo $'url:\t\t'$src_url;
  echo $'local:\t\t'$dest_fn;
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

  web_url="$(grep "$login_hostname" courts.json -B 2 -A 2 | grep '"web_url":' | cut -d '"' -f 4)";
  echo $'\n\n----------\n'
  echo $'login url:\t' $login_hostname;
  echo $'web url:\t' $web_url;
  [[ ! "$web_url" = "" ]] && fetch "$web_url" "artifacts/pages/${dest_slug}/www.html";
  echo $'\n----------\n\n'

  fetch "https://$login_hostname" "artifacts/pages/${dest_slug}/ecf.html";

  fetch "https://$login_hostname/cgi-bin/rss_outside.pl" "artifacts/rss/${dest_slug}/rss-format-1.xml";
  fetch "https://$login_hostname/n/beam/servlet/TransportRoom?servlet=RSSGenerator" "artifacts/rss/${dest_slug}/rss-format-2.xml";

  mkdir -p "artifacts/rss/$dest_slug/raw"
  status="$(grep -ri '200 OK' "artifacts/rss/$dest_slug/" --files-with-matches | grep '\.headers')"
  latest_valid_rss=""
  if [[ ! "$status" = "" ]]; then
    latest_valid_rss="${status%.*}"
    
    cat "./$latest_valid_rss" > "latest/rss/${dest_slug}.rss.xml"
    date_saved="$(date -u)"

    if [ -f "$PWD/latest/rss/$dest_slug.rss.xml.missing" ]; then
      git rm $latest_valid_rss "latest/rss/$dest_slug.rss.xml.missing" --silent;
    fi
  fi

  diff_num_changes="$(git diff -- "latest/rss/${dest_slug}.rss.xml" | grep '@@' | wc -l)"
  if [[ "$diff_num_changes" -lt 2 ]]; then
    echo 'NOTICE: RSS channel items unchanged. git commit skipped.'
    exit 0
  fi

  git add -A

  commit_msg="Update ${dest_slug} court feeds and pages.${commit_msg_suffix}"

  git commit -m "$commit_msg";
  git push;

  if [[ ! -f "latest/rss/${dest_slug}.rss.xml" ]]; then
    touch $latest_valid_rss "latest/rss/$dest_slug.rss.xml.missing"
    git add "latest/rss/$dest_slug.rss.xml.missing";
    commit_msg="Missing ${dest_slug} court feed.${commit_msg_suffix}"
    git commit -m "$commit_msg";
    git push || true;
  fi
}

commit_msg_suffix=`printf $'\n\t\nLast Updated:\t%s\nFetched:\t%s\nSaved:\t%s\n' "$date_source_last_updated" "$date_fetched" "$date_saved"`

# check rss for in each file
for court_id in `cat courts.json | grep '"login_url":' | cut -d '/' -f3 | tr -d "," | tr -d '"' | sort -u | sed -e 's/www\.//g' | sort -u | cut -d '.' -f 1- | sort -u | grep -v "pcl\.uscourts\.gov"`; do
  court_html_origin="$(echo $court_id | tr -d '"')"
  fetch_rss "$court_html_origin" || true
done

# git push || exit 0
