#!/bin/bash

INPUT_FILE="${INPUT_FILE:=1}"
XMLLINT="xmllint"

if ! command -v "${XMLLINT}" > /dev/null; then
  echo "Error: Cannot find ${XMLLINT} binary. Installing the package . . ."
  sudo apt-get install libxml2-utils -y
fi

xmllint=$(command -v "${XMLLINT}")

xmllint --format --recover "$INPUT_FILE"
