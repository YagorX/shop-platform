import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  insecureSkipTLSVerify: true,
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

const BASE = __ENV.BASE_URL || 'https://127.0.0.1:8083';
const APP_ID = Number(__ENV.APP_ID || '1');

export function setup() {
  const suffix = `${Date.now()}-${Math.floor(Math.random() * 100000)}`;
  const username = `k6-${suffix}`;
  const email = `${username}@example.com`;
  const password = 'Test123!';
  const deviceId = `k6-device-${suffix}`;

  const registerRes = http.post(
    `${BASE}/auth/register`,
    JSON.stringify({ username, email, password }),
    {
      headers: { 'Content-Type': 'application/json' },
    },
  );
  check(registerRes, { 'register status 200': (r) => r.status === 200 });

  const loginRes = http.post(
    `${BASE}/auth/login`,
    JSON.stringify({
      email_or_name: username,
      password,
      app_id: APP_ID,
      device_id: deviceId,
    }),
    {
      headers: { 'Content-Type': 'application/json' },
    },
  );
  check(loginRes, { 'login status 200': (r) => r.status === 200 });

  const loginBody = loginRes.json();

  return {
    accessToken: loginBody.access_token,
  };
}

export default function (data) {
  const headers = {
    Authorization: `Bearer ${data.accessToken}`,
    'X-App-Id': String(APP_ID),
  };

  let res1 = http.get(`${BASE}/products?limit=2&offset=0`, { headers });
  check(res1, { 'products status 200': (r) => r.status === 200 });

  let res2 = http.get(`${BASE}/products/prod-001`, { headers });
  check(res2, { 'product by id status 200': (r) => r.status === 200 });

  sleep(1);
}
