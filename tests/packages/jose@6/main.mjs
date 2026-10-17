// From the README of jose: sign a JWT with a fixed key and time, verify it, and decode it.
import { SignJWT, base64url, decodeJwt, jwtVerify } from "jose";

const secret = new TextEncoder().encode("a fixed secret of at least 32 bytes!");
const token = await new SignJWT({ role: "admin" })
  .setProtectedHeader({ alg: "HS256" })
  .setSubject("user-7")
  .setIssuedAt(1767225600)
  .setExpirationTime(1767229200)
  .sign(secret);
console.log(token);
const { payload, protectedHeader } = await jwtVerify(token, secret, {
  currentDate: new Date(1767226000 * 1000),
});
console.log(JSON.stringify(payload), JSON.stringify(protectedHeader));
console.log(JSON.stringify(decodeJwt(token)));
console.log(new TextDecoder().decode(base64url.decode("aGVsbG8")));
try {
  await jwtVerify(token, secret, { currentDate: new Date(1767230000 * 1000) });
} catch (error) {
  console.log(error.code);
}
