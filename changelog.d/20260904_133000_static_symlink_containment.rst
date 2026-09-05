Security
--------

- Static-file serving now rejects symlinks that resolve outside the configured
  public directory, preventing files outside that root from being served on
  first access or after another file has populated the directory cache.
  Symlinks that resolve within the public directory, including a symlinked
  public root, remain supported. (#257)
