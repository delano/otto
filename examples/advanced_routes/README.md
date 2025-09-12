# Otto Advanced Routes Example

This example demonstrates the advanced routing syntax features available in Otto, such as response type negotiation, CSRF exemptions, and routing to logic classes.

## Project Structure

The example is structured to separate concerns, making it easier to navigate:

-   `config.ru`: The main Rackup file that loads and runs the Otto application.
-   `routes`: A comprehensive file demonstrating various advanced routing syntaxes. This file serves as a good reference.
-   `app.rb`: A simple loader that requires all controller and logic files.
-   `app/controllers/`: Contains the `RoutesApp` class and other namespaced controller modules that handle incoming requests.
-   `app/logic/`: Contains various "Logic Classes". These are special classes that can be routed to directly, encapsulating business logic for a specific route. They are organized into namespaces to show how Otto handles complex class names.
-   `run.rb`, `puma.rb`, `test.rb`: Alternative ways to run or test the application.

## Key Features Demonstrated

-   **Response Types:** Defining `response=json`, `response=view`, etc., directly in the `routes` file.
-   **CSRF Exemption:** Using `csrf=exempt` for APIs or webhooks.
-   **Logic Classes:** Routing directly to a class (e.g., `GET /logic/simple SimpleLogic`). Otto automatically instantiates it and calls its `process` method.
-   **Namespaced Targets:** Routing to deeply namespaced classes and modules (e.g., `GET /logic/v2/dashboard V2::Logic::Dashboard`).
-   **Custom Parameters:** Adding arbitrary key-value parameters to a route for custom logic.

## Running the Example

1.  Make sure you have the necessary gems installed (`bundle install`).
2.  Run the application from the root of the `otto` project:

    ```sh
    rackup examples/advanced_routes/config.ru
    ```

3.  The application will be running at `http://localhost:9292`. You can use `curl` or your browser to test the various routes defined in the `routes` file.
