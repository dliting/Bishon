// sameRequestNum: 2 // per-request concurrency limit
const quene = {
  axios: null as any,
  queneLen: 2,
  requests: {} as any, // url:[config,config]
  watings: {} as any, // url:[config]
  close: false, // enabled by default; flip to disable
  isCanRequest() {
    // Whether a new request can be fired.
    if (this.close || Object.keys(this.requests).length < this.queneLen) {
      return true;
    }
    return false;
  },
  addRequest(config: any) {
    const key = this.getKey(config);
    this.requests[key] = config;
  },
  removeRequest(config: any) {
    const key = this.getKey(config);
    delete this.requests[key];
  },
  addWating(config: any) {
    this.watings.push(config);
  },
  removeWating() {
    // this.watings.shift();
  },
  getKey(config: any) {
    return `${config.url}&request_type=${config.method}`;
  },

  cancel(config: any) {
    const { CancelToken } = this.axios as any;
    // eslint-disable-next-line no-param-reassign
    config.cancelToken = new CancelToken((cancel: () => {}) => {
      cancel();
    });
  },
  startRequest(config: any) {
    this.axios(config);
  },
  move() {
    if (this.watings.length === 0) {
      return;
    }
    const nextRequestConfig = this.removeWating();
    this.startRequest(nextRequestConfig);
    this.addRequest(nextRequestConfig);
  },
  start(config: any, axios: any) {
    // Entry point.
    this.axios = axios;
    if (this.isCanRequest()) {
      // Fire the request.
      this.addRequest(config);
    } else {
      this.cancel(config);
      this.addWating(config);
    }
  },
};
function response(res: any) {
  quene.move();
  return res;
}

function request(config: any, axios: any) {
  quene.start(config, axios);
  return config;
}
console.log('zxx--quene---', request, response);
export default {
  // request,
  // response,
  // error: response,
  quene,
};
