FROM nodered/node-red

RUN npm install node-red-contrib-sm-8relind@"^1.0.3"
RUN npm install node-red-contrib-cron-plus@"^2.1.0"
