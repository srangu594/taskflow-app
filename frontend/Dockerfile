# ── Stage 1: Build React app
FROM node:20-alpine AS builder
WORKDIR /app

# Install dependencies first (cached layer if package.json unchanged)
COPY package.json ./
RUN npm install

# Copy source and build
COPY . .
ARG REACT_APP_API_URL=/api
ENV REACT_APP_API_URL=$REACT_APP_API_URL
# CI=false: treat warnings as warnings, not errors (prevents build failures on minor warnings)
RUN CI=false npm run build

# ── Stage 2: Serve with Nginx
FROM nginx:1.25-alpine
COPY --from=builder /app/build /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD wget -qO- http://localhost/health || exit 1
CMD ["nginx", "-g", "daemon off;"]
