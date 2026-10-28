FROM node:24.19.0-alpine3.24 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:24.19.0-alpine3.24 AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force \
    # npm/corepack are only needed to install packages: dropping them shrinks the image
    # and removes their dependencies from the vulnerability scan
    && rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
              /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /opt/yarn-* \
              /usr/local/bin/yarn /usr/local/bin/yarnpkg
COPY --from=builder /app/dist ./dist
# the "node" user (uid 1000) that ships with the image — no root at runtime
USER node
EXPOSE 3001
CMD ["node", "dist/index.js"]
