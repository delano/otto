Fixed
-----

- A request to the MCP endpoint whose body is valid JSON but not an object,
  such as a batch array or a bare number, is answered with ``400`` and
  ``-32600``. It was answered with ``500``, with or without
  ``enable_validation``. With ``Rack::Attack`` mounted, the ``tools/call``
  throttle raised on such a body before Otto saw the request; it now leaves
  the body uncounted.

- These requests to the MCP endpoint are answered with ``400`` where they
  were answered with ``500``: ``params`` that is not an object, with
  ``enable_validation: false``; a body with bytes that are not UTF-8 inside a
  string; and a body with a number such as ``1e400``, which Ruby's JSON
  parser reads as ``Infinity``. The last two are refused as invalid JSON
  before anything is dispatched, so a tool handler no longer receives
  ``Infinity`` as an argument.
