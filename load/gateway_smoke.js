import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  stages: [
    { duration: '30s', target: 10 },
    { duration: '1m', target: 30 },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<800'],
  },
};

const BASE = __ENV.BASE_URL || 'http://127.0.0.1:8083';

export default function () {
  let res1 = http.get(`${BASE}/products?limit=2&offset=0`);
  check(res1, { 'products status 200': (r) => r.status === 200 });

  let res2 = http.get(`${BASE}/products/prod-001`);
  check(res2, { 'product by id status 200': (r) => r.status === 200 });

  sleep(1);
}
