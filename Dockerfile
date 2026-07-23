FROM elixir:1.19-alpine

RUN apk add --no-cache postgresql-client nodejs npm git make gcc musl-dev linux-headers inotify-tools

RUN mix local.hex --force && \
    mix local.rebar --force

RUN npm install -g esbuild tailwindcss

EXPOSE 4000

WORKDIR /app

CMD ["mix", "phx.server"]
