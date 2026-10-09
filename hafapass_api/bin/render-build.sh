#!/usr/bin/env bash
# Render builds install dependencies only; the web service's pre-deploy command
# owns database migrations once for the release.
set -o errexit

gem install bundler -v "$(grep -A1 'BUNDLED WITH' Gemfile.lock | tail -1 | tr -d ' ')"
bundle install
