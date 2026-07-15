To run the app locally going forward, you need both processes running together:

1. Rails server (single-process Puma, avoids the earlier mini_racer/fork crash):
DISCOURSE_MULTISITE_CONFIG_PATH=config/multisite.local.yml DISCOURSE_REDIS_HOST=localhost RAILS_ENV=development bin/rails server -p 3000
2. Frontend bundler (serves compiled JS/assets, required for the UI to actually render):
pnpm --dir frontend/discourse start