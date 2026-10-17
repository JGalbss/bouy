// From the README of pkce-challenge: the challenge of a fixed verifier, and its check.
import { generateChallenge, verifyChallenge } from "pkce-challenge";

const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const challenge = await generateChallenge(verifier);
console.log(challenge);
console.log(await verifyChallenge(verifier, challenge), await verifyChallenge("other", challenge));
