// From the README of cors: the headers that the middleware sets for a simple request and a
// preflight, with stand-ins for the request and the response.
import cors from "cors";

function run(middleware, method, headers) {
  const set = {};
  const response = {
    statusCode: 200,
    setHeader: (name, value) => (set[name.toLowerCase()] = value),
    getHeader: (name) => set[name.toLowerCase()],
    end: () => console.log("ended", response.statusCode),
  };
  middleware({ method, headers }, response, () => console.log("next"));
  console.log(JSON.stringify(Object.entries(set).sort()));
}
run(cors(), "GET", { origin: "http://a.example" });
run(cors({ origin: "http://a.example", credentials: true }), "OPTIONS", {
  origin: "http://a.example",
  "access-control-request-method": "PUT",
});
