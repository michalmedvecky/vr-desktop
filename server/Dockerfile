# Build from the repository root:  docker build -f server/Dockerfile -t vr-desktop-server .
FROM node:22-alpine
ENV NODE_ENV=production PORT=8080 WEB_ROOT=/app/web
WORKDIR /app
COPY server/package.json server/package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY server/server.js ./
COPY mac/Web/ ./web/
USER node
EXPOSE 8080
HEALTHCHECK CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1
CMD ["node", "server.js"]
