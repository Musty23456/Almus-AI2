FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json ./
COPY *.js ./
RUN rm -f *.test.js
USER node
EXPOSE 8080
CMD ["node", "index.js"]
