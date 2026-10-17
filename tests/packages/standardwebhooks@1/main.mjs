// From the README of standardwebhooks: sign a payload with a fixed secret, id, and time. The
// program leaves out verify, which reads the clock.
import { Webhook } from "standardwebhooks";

const webhook = new Webhook("MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw");
const payload = JSON.stringify({ type: "user.created", id: 7 });
const signature = webhook.sign("msg_7", new Date(1767225600 * 1000), payload);
console.log(signature);
console.log(signature === webhook.sign("msg_7", new Date(1767225600 * 1000), payload));
console.log(webhook.sign("msg_8", new Date(1767225600 * 1000), payload) === signature);
