# Otto Security Features Example

This example application demonstrates the built-in security features of the Otto framework. It is configured to be secure by default and provides a showcase of best practices.

## Security Features Demonstrated

*   **CSRF Protection:** All POST forms are protected with a CSRF token to prevent cross-site request forgery attacks.
*   **Input Validation:** All user-submitted data is validated on the server-side for length and content, preventing common injection attacks.
*   **XSS Prevention:** All output is properly escaped to prevent cross-site scripting (XSS). You can test this by submitting `<script>alert('XSS')</script>` in any form.
*   **Secure File Uploads:** File uploads are validated, and filenames are sanitized to prevent directory traversal and other file-based attacks.
*   **Security Headers:** The application sends important security headers like `Content-Security-Policy`, `Strict-Transport-Security`, and `X-Frame-Options`.
*   **Request Limiting:** The application is configured to limit the maximum request size, parameter depth, and number of parameter keys to prevent denial-of-service attacks.
*   **Trusted Proxies:** The configuration includes a list of trusted proxy servers, ensuring that `X-Forwarded-*` headers are handled correctly and securely.

## How to Run

1.  Make sure you have `bundler` and `thin` installed:
    ```sh
    gem install bundler thin
    ```

2.  Install the dependencies from the root of the project:
    ```sh
    bundle install
    ```

3.  Start the server from this directory (`examples/security_features`):
    ```sh
    thin -e dev -R config.ru -p 10770 start
    ```

4.  Open your browser and navigate to `http://localhost:10770`.

## What to Test

*   **XSS Protection:** Try entering `<script>alert("XSS")</script>` into any of the form fields. You will see that the input is safely displayed as text instead of being executed as a script.
*   **Input Validation:** Try submitting a very long message in the feedback form to see the length validation in action.
*   **File Uploads:** Try uploading different types of files. The application will show you how it sanitizes the filename.
*   **Security Headers:** Open your browser's developer tools and inspect the network requests. You will see the security headers in the response. You can also visit the `/headers` path to see a JSON representation of the request headers your browser is sending.

## File Structure

*   `README.md`: This file.
*   `app.rb`: The main application logic, demonstrating how to handle forms, file uploads, and user input in a secure way.
*   `config.ru`: The Rack configuration file. This is where the security features are enabled and configured for the Otto application.
*   `routes`: Defines the URL routes and maps them to methods in the `SecureApp` class.
