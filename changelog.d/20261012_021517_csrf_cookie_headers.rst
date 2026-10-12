Security
--------

- ``CSRFMiddleware`` now adds ``Cache-Control: private, stale-if-error=0`` to
  a response on which it sets the CSRF binding cookie or injects a token,
  unless the application set ``Cache-Control`` or ``Expires`` on it. Both are
  meant for one client, and RFC 9111, section 7.3, notes that "the Set-Cookie
  response header field [COOKIE] does not inhibit caching". A shared cache
  that stored such a response could hand one client's binding cookie, with the
  token bound to it, to other clients, or serve a page with a token bound to
  one user's session to everyone. Section 5.2.2.7 says of ``private`` that "a
  shared cache MUST NOT store the response". The browser's own cache may still
  store it. ``stale-if-error=0`` (RFC 5861) is for CloudFront, which stores
  such a response when the cache policy's minimum TTL is above 0, as in the
  managed CachingOptimized policy. For that case the CloudFront developer
  guide says: "If the origin is unreachable and the minimum or maximum TTL
  value is greater than 0, CloudFront will serve the object that it got from
  the origin previously. To avoid this behavior, include the Cache-Control:
  stale-if-error=0 directive with the object returned from the origin." An
  application value, including one that lets shared caches store the response
  such as ``public, max-age=60``, is kept as is. A token the application
  writes into a response itself, which Otto does not change, needs its own
  ``Cache-Control``. Otto does not read fields that some caches give
  precedence over ``Cache-Control``, such as ``CDN-Cache-Control``,
  ``Surrogate-Control`` or ``X-Accel-Expires``. See
  ``docs/guides/authentication.md``. (#PR)

Changed
-------

- With CSRF protection enabled, responses on which ``CSRFMiddleware`` sets the
  binding cookie, HTML or not, and HTML pages into which it injects a token
  now carry ``Cache-Control: private, stale-if-error=0`` when the application
  sets neither ``Cache-Control`` nor ``Expires``. An HTML file served from
  ``public:`` or ``mount_static`` gets no token, so it carries the header only
  on a response that sets the binding cookie. A shared cache that honors
  ``private`` no longer stores these responses, including one that stored
  them before under a default TTL. ``Rack::ETag`` mounted outside Otto adds
  its default ``Cache-Control``, ``max-age=0, private, must-revalidate``,
  only when the response has none, so these responses no longer get it. (#PR)

Fixed
-----

- ``CSRFMiddleware`` no longer changes the application's headers on HTML
  responses; it works on a copy, as it already did on other responses. Before,
  frozen headers raised ``FrozenError``, and an application that returned the
  same headers object for every response carried each client's binding cookie
  into the responses for later clients. (#PR)

- ``CSRFMiddleware`` no longer adds the binding cookie to a response that
  already sets a cookie of that name, as one does when the middleware runs
  more than once for a request: added again around an Otto with CSRF
  protection, or in nested CSRF-enabled Ottos (for example an Otto whose
  ``not_found=`` is another Otto). The first, innermost, middleware's cookie
  is kept. With one configuration the two cookies were identical. Without
  session middleware, Ottos with different ``csrf_session_key`` values mint
  different bindings; the browser kept the outer Otto's, and the inner Otto,
  which checks the requests its routes receive, rejected the tokens it issued
  on that page with ``403``. Those tokens now pass. The outer Otto still
  injects its own ``csrf-token`` meta tag, ahead of the inner Otto's, and its
  token now fails on the page that set the cookie in that case; it passes
  only when the two Ottos share ``csrf_secret`` and resolve the same binding,
  as they do once the client sends the cookie back. (#PR)

- ``CSRFMiddleware`` now reads an HTML body through ``#to_ary``. The Rack
  specification says "middleware can only process the Body directly if it
  responds to +to_ary+", and that "If the Body responds to both +to_ary+ and
  +close+, its implementation of +to_ary+ must call +close+." Before, the
  middleware injected the token only into a body that responds to ``join``: a
  body wrapped by ``Rack::Lint`` got no token, and a ``Rack::BodyProxy`` was
  replaced without being closed, so its close callback never ran. Other
  bodies, such as files and streams, are still returned unread. (#PR)
