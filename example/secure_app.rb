# example/secure_app.rb

class SecureApp
  # An instance of Rack::Request
  attr_reader :req
  # An instance of Rack::Response  
  attr_reader :res

  # Otto creates an instance of this class for every request
  # and passes the Rack::Request and Rack::Response objects.
  def initialize(req, res)
    @req = req
    @res = res
    res.headers['content-type'] = 'text/html; charset=utf-8'
  end

  def index
    # CSRF token will be automatically injected into HTML responses
    # when CSRF protection is enabled
    csrf_tag = respond_to?(:csrf_form_tag) ? csrf_form_tag : ''

    lines = <<~HTML
      <h1>Secure Otto App Example</h1>
      <h2>Security Features Demo</h2>
      <div style="margin: 20px 0;">
        <h3>Send Feedback (CSRF Protected)</h3>
        <form method="post" action="/feedback">
          #{csrf_tag}
          <label>Message:</label><br>
          <textarea name="message" rows="4" cols="50" placeholder="Enter your feedback..."></textarea><br><br>
          <input type="submit" value="Submit Feedback">
        </form>
      </div>
      <div style="margin: 20px 0;">
        <h3>File Upload (Validation Demo)</h3>
        <form method="post" action="/upload" enctype="multipart/form-data">
          #{csrf_tag}
          <label>Choose file:</label><br>
          <input type="file" name="upload_file"><br><br>
          <input type="submit" value="Upload File">
        </form>
      </div>
      <div style="margin: 20px 0;">
        <h3>User Profile (Input Validation)</h3>
        <form method="post" action="/profile">
          #{csrf_tag}
          <label>Name:</label><br>
          <input type="text" name="name" placeholder="Your name"><br><br>
          <label>Email:</label><br>
          <input type="email" name="email" placeholder="your@email.com"><br><br>
          <label>Bio:</label><br>
          <textarea name="bio" rows="3" cols="50" placeholder="Tell us about yourself..."></textarea><br><br>
          <input type="submit" value="Update Profile">
        </form>
      </div>
      <div style="margin: 20px 0;">
        <p><strong>Security Headers:</strong> Check your browser's developer tools to see the security headers in action!</p>
        <p><strong>Try an XSS attack:</strong> Enter <code>&lt;script&gt;alert("XSS")&lt;/script&gt;</code> in any form field.</p>
        <p><strong>View Headers:</strong> <a href="/headers">See all request headers</a></p>
      </div>
    HTML

    res.body = html_wrapper(lines)
  end

  def receive_feedback
    begin
      # Validate and sanitize the message input
      message = req.params['message']
      
      if respond_to?(:validate_input)
        # Use built-in validation helper
        safe_message = validate_input(message, max_length: 1000, allow_html: false)
      else
        # Basic fallback validation
        safe_message = message.to_s.strip
        if safe_message.length > 1000
          raise "Message too long"
        end
      end
      
      if safe_message.empty?
        content = [
          '<h2>Error</h2>',
          '<p style="color: red;">Message cannot be empty.</p>',
          '<p><a href="/">← Back to form</a></p>'
        ]
      else
        content = [
          '<h2>Feedback Received</h2>',
          '<p style="color: green;">Thank you for your feedback!</p>',
          '<div style="background: #f0f0f0; padding: 10px; margin: 10px 0; border-radius: 5px;">',
          "<p><strong>Your message:</strong></p>",
          "<p>#{escape_html(safe_message)}</p>",
          '</div>',
          '<p><a href="/">← Back to form</a></p>'
        ]
      end
      
    rescue Otto::Security::ValidationError => e
      content = [
        '<h2>Security Validation Failed</h2>',
        "<p style=\"color: red;\">#{escape_html(e.message)}</p>",
        '<p>Please check your input and try again.</p>',
        '<p><a href="/">← Back to form</a></p>'
      ]
    rescue => e
      content = [
        '<h2>Error</h2>',
        '<p style="color: red;">An error occurred processing your request.</p>',
        '<p><a href="/">← Back to form</a></p>'
      ]
    end
    
    res.body = html_wrapper(content.join("\n"))
  end

  def upload_file
    begin
      uploaded_file = req.params['upload_file']
      
      if uploaded_file.nil? || uploaded_file.empty?
        content = [
          '<h2>Upload Error</h2>',
          '<p style="color: red;">No file was selected.</p>',
          '<p><a href="/">← Back to form</a></p>'
        ]
      else
        # Get the original filename
        filename = uploaded_file[:filename] rescue uploaded_file.original_filename rescue 'unknown'
        
        # Sanitize the filename using security helper if available
        if respond_to?(:sanitize_filename)
          safe_filename = sanitize_filename(filename)
        else
          # Basic filename sanitization
          safe_filename = File.basename(filename.to_s).gsub(/[^\w\-_\.]/, '_')
        end
        
        content = [
          '<h2>File Upload Successful</h2>',
          '<p style="color: green;">File processed successfully!</p>',
          '<div style="background: #f0f0f0; padding: 10px; margin: 10px 0; border-radius: 5px;">',
          "<p><strong>Original filename:</strong> #{escape_html(filename)}</p>",
          "<p><strong>Sanitized filename:</strong> #{escape_html(safe_filename)}</p>",
          "<p><strong>Content type:</strong> #{escape_html(uploaded_file[:type] || 'unknown')}</p>",
          '</div>',
          '<p><em>Note: This is a demo - files are not actually stored.</em></p>',
          '<p><a href="/">← Back to form</a></p>'
        ]
      end
      
    rescue Otto::Security::ValidationError => e
      content = [
        '<h2>File Validation Failed</h2>',
        "<p style=\"color: red;\">#{escape_html(e.message)}</p>",
        '<p><a href="/">← Back to form</a></p>'
      ]
    rescue => e
      content = [
        '<h2>Upload Error</h2>',
        '<p style="color: red;">An error occurred during file upload.</p>',
        '<p><a href="/">← Back to form</a></p>'
      ]
    end
    
    res.body = html_wrapper(content.join("\n"))
  end

  def update_profile
    begin
      name = req.params['name']
      email = req.params['email'] 
      bio = req.params['bio']
      
      # Validate inputs using security helpers if available
      if respond_to?(:validate_input)
        safe_name = validate_input(name, max_length: 100)
        safe_email = validate_input(email, max_length: 255)
        safe_bio = validate_input(bio, max_length: 500, allow_html: false)
      else
        # Basic validation fallback
        safe_name = name.to_s.strip[0..99]
        safe_email = email.to_s.strip[0..254]
        safe_bio = bio.to_s.strip[0..499]
      end
      
      # Basic email format validation
      unless safe_email.match?(/\A[^@\s]+@[^@\s]+\z/)
        raise Otto::Security::ValidationError, "Invalid email format"
      end
      
      content = [
        '<h2>Profile Updated</h2>',
        '<p style="color: green;">Your profile has been updated successfully!</p>',
        '<div style="background: #f0f0f0; padding: 10px; margin: 10px 0; border-radius: 5px;">',
        "<p><strong>Name:</strong> #{escape_html(safe_name)}</p>",
        "<p><strong>Email:</strong> #{escape_html(safe_email)}</p>",
        "<p><strong>Bio:</strong> #{escape_html(safe_bio)}</p>",
        '</div>',
        '<p><a href="/">← Back to form</a></p>'
      ]
      
    rescue Otto::Security::ValidationError => e
      content = [
        '<h2>Profile Validation Failed</h2>',
        "<p style=\"color: red;\">#{escape_html(e.message)}</p>",
        '<p>Please check your input and try again.</p>',
        '<p><a href="/">← Back to form</a></p>'
      ]
    rescue => e
      content = [
        '<h2>Profile Update Error</h2>',
        '<p style="color: red;">An error occurred updating your profile.</p>',
        '<p><a href="/">← Back to form</a></p>'
      ]
    end
    
    res.body = html_wrapper(content.join("\n"))
  end

  def show_headers
    res.headers['content-type'] = 'application/json; charset=utf-8'
    
    # Show request headers (filtered for security)
    safe_headers = {}
    req.env.each do |key, value|
      if key.start_with?('HTTP_') || %w[REQUEST_METHOD PATH_INFO QUERY_STRING].include?(key)
        safe_headers[key] = value.to_s[0..200] # Limit length for safety
      end
    end
    
    response_data = {
      message: "Request headers (filtered for security)",
      client_ip: req.respond_to?(:client_ipaddress) ? req.client_ipaddress : req.ip,
      secure_connection: req.respond_to?(:secure?) ? req.secure? : false,
      headers: safe_headers
    }
    
    require 'json'
    res.body = JSON.pretty_generate(response_data)
  end

  def not_found
    res.status = 404
    content = [
      '<h2>Page Not Found</h2>',
      '<p>The requested page could not be found.</p>',
      '<p><a href="/">← Back to home</a></p>'
    ]
    res.body = html_wrapper(content.join("\n"))
  end

  def server_error
    res.status = 500
    error_id = req.env['otto.error_id'] || 'unknown'
    content = [
      '<h2>Server Error</h2>',
      '<p>An internal server error occurred.</p>',
      "<p><small>Error ID: #{escape_html(error_id)}</small></p>",
      '<p><a href="/">← Back to home</a></p>'
    ]
    res.body = html_wrapper(content.join("\n"))
  end

  private

  def escape_html(text)
    return '' if text.nil?
    text.to_s
        .gsub('&', '&amp;')
        .gsub('<', '&lt;')
        .gsub('>', '&gt;')
        .gsub('"', '&quot;')
        .gsub("'", '&#x27;')
  end

  def html_wrapper(content)
    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Secure Otto App</title>
          <style>
              body { 
                  font-family: Arial, sans-serif; 
                  max-width: 800px; 
                  margin: 0 auto; 
                  padding: 20px;
                  background-color: #f9f9f9;
              }
              .container {
                  background: white;
                  padding: 20px;
                  border-radius: 8px;
                  box-shadow: 0 2px 4px rgba(0,0,0,0.1);
              }
              form {
                  background: #f8f9fa;
                  padding: 15px;
                  border-radius: 5px;
                  border: 1px solid #dee2e6;
              }
              input[type="text"], input[type="email"], textarea {
                  width: 100%;
                  padding: 8px;
                  margin: 5px 0;
                  border: 1px solid #ccc;
                  border-radius: 4px;
                  box-sizing: border-box;
              }
              input[type="submit"] {
                  background-color: #007bff;
                  color: white;
                  padding: 10px 20px;
                  border: none;
                  border-radius: 4px;
                  cursor: pointer;
              }
              input[type="submit"]:hover {
                  background-color: #0056b3;
              }
              code {
                  background: #f1f1f1;
                  padding: 2px 4px;
                  border-radius: 3px;
                  font-family: monospace;
              }
          </style>
      </head>
      <body>
          <div class="container">
              #{content}
          </div>
      </body>
      </html>
    HTML
  end
end