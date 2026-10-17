// From the README of google-auth-library: an OAuth2 client and the URL of its consent page.
import { OAuth2Client } from "google-auth-library";

const client = new OAuth2Client({
  clientId: "client-7.apps.googleusercontent.com",
  clientSecret: "secret",
  redirectUri: "http://127.0.0.1:9/callback",
});
const url = client.generateAuthUrl({
  access_type: "offline",
  scope: ["https://www.googleapis.com/auth/userinfo.email"],
  state: "fixed-state",
});
const parsed = new URL(url);
console.log(parsed.origin + parsed.pathname);
console.log(JSON.stringify([...parsed.searchParams.entries()].sort()));
client.setCredentials({ access_token: "token-7", expiry_date: 1767229200000 });
console.log(client.credentials.access_token);
