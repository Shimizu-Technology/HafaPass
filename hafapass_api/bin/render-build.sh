#!/usr/bin/env bash
# Render build script — installs matching Bundler and runs migrations
set -o errexit

gem install bundler -v "$(grep -A1 'BUNDLED WITH' Gemfile.lock | tail -1 | tr -d ' ')"
bundle install
bundle exec rails db:migrate
