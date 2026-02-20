FROM ruby:3.3.4-slim

RUN apt-get update -qq && \
    apt-get install -y build-essential libpq-dev curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN bundle config set --local without 'development test' && \
    bundle install

COPY . .

EXPOSE 10000

CMD ["sh", "-c", "bundle exec rails db:migrate && bundle exec rails server -b 0.0.0.0 -p ${PORT:-10000}"]
