# Otto - Authentication Strategies Example

This example demonstrates how to use Otto's powerful authentication features.

## Structure

*   `config.ru`: The Rackup file. It initializes Otto and loads the authentication strategies.
*   `routes`: Defines the application's routes and the authentication required for each.
*   `app/auth.rb`: Contains the definitions for all authentication strategies. This is where you would add your own.
*   `app/controllers/`: Contains the controller classes that handle requests.

## Running the Demo

1.  Make sure you have the necessary gems installed (`bundle install`).
2.  Run the application from the root of the `otto` project:

    ```sh
    rackup examples/authentication_strategies/config.ru
    ```

3.  Open your browser and navigate to `http://localhost:9292`.

## Trying the Authentication Strategies

You can test the different authentication strategies by providing a `token` or `api_key` parameter in the URL.

*   **Authenticated User:** [http://localhost:9292/profile?token=demo_token](http://localhost:9292/profile?token=demo_token)
*   **Admin User:** [http://localhost:9292/admin?token=admin_token](http://localhost:9292/admin?token=admin_token)
*   **User with 'write' permission:** [http://localhost:9292/edit?token=demo_token](http://localhost:9292/edit?token=demo_token)
*   **API Key:** [http://localhost:9292/api/data?api_key=demo_api_key_123](http://localhost:9292/api/data?api_key=demo_api_key_123)

If you try to access a protected route without the correct token, you'll get an authentication error.
