FROM nginx:1.27-alpine
  ARG APP_VERSION=latest
  COPY public/ /usr/share/nginx/html/
  RUN chmod -R a+rX /usr/share/nginx/html \
   && printf '{"version":"%s"}\n' "$APP_VERSION" > /usr/share/nginx/html/version.json