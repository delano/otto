Security
--------

- ``CSRFMiddleware`` now adds ``Cache-Control: private`` to a response on
  which it sets the CSRF binding cookie or injects a token, unless the
  application set ``Cache-Control`` or ``Expires`` on it. Both are meant for
  one client, and RFC 9111, section 7.3, notes that "the Set-Cookie response
  header field [COOKIE] does not inhibit caching". A shared cache that stored
  such a response could hand one client's binding cookie, with the token bound
  to it, to other clients, or serve a page with a token bound to one user's
  session to everyone. Section 5.2.2.7 says of ``private`` that "a shared cache
  MUST NOT store the response". The browser's own cache may still store it. An
  application value, including one that lets shared caches store the response
  such as ``public, max-age=60``, is kept as is. A token the application writes
  into a response itself, which Otto does not change, needs its own
  ``Cache-Control``. See ``docs/guides/authentication.md``. (#PR)

Changed
-------

- With CSRF protection enabled, HTML pages with a ``<head>`` element, and HTML
  responses that set the binding cookie, now carry ``Cache-Control: private``
  when the application sets neither ``Cache-Control`` nor ``Expires``. A shared
  cache that honors ``private`` no longer stores them, including one that
  stored them before under a default TTL. (#PR)

Fixed
-----

- ``CSRFMiddleware`` no longer changes the application's headers on HTML
  responses; it works on a copy, as it already did on other responses. Before,
  frozen headers raised ``FrozenError``, and an application that returned the
  same headers object for every response carried each client's binding cookie
  into the responses for later clients. (#PR)
