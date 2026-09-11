FROM node:20-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
COPY public ./public
ARG APP_VERSION=latest
ENV APP_VERSION=${APP_VERSION}
ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "src/server.js"]
