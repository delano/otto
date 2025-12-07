Fixed
-----

- Rate limiters now respect route ``response=json`` declarations when returning
  throttled responses, matching the error handler fix for consistent content
  negotiation across all error paths.

- ClassMethodHandler direct testing context now respects route ``response_type``
  when generating error responses.
