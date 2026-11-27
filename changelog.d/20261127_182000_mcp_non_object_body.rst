Fixed
-----

- A request to the MCP endpoint whose body is valid JSON but not an object,
  such as a batch array or a bare number, is answered with ``400`` and
  ``-32600``. It was answered with ``500``, with or without
  ``enable_validation``.
