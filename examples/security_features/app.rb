# examples/security_features/app.rb (Updated with Design System)

require_relative '../../lib/otto/design_system'

class SecureApp
  include Otto::DesignSystem
  include Otto::Security::CSRFHelpers

  attr_reader :req, :res

  def initialize(req, res)
    @req = req
    @res = res
    res.headers['content-type'] = 'text/html; charset=utf-8'
  end

  def otto
    self.class.otto
  end

  def index
    csrf_tag = respond_to?(:csrf_form_tag) ? csrf_form_tag : ''

    content = <<~HTML
      <div class="otto-card otto-text-center">
        <img src="/img/otto.jpg" alt="Otto Framework" class="otto-logo" />
        <h1>Otto Security Features</h1>
        <p class="otto-mb-md">Security demonstration for the Otto framework</p>
      </div>

      #{otto_card("CSRF Protected Feedback") do

        <<~FORM
          <form method="post" action="/feedback" class="otto-form">
            #{csrf_tag}
            <label>Message:</label>
            #{otto_textarea("message", placeholder: "Enter your feedback...", required: true)}
            #{otto_button("Submit Feedback", variant: "primary")}
          </form>
        FORM

      end}

      #{otto_card("File Upload Validation") do
        <<~UPLOAD
          <form method="post" action="/upload" enctype="multipart/form-data" class="otto-form">
            #{csrf_tag}
            <label>Choose file:</label>
            <input type="file" name="upload_file" class="otto-input">
            #{otto_button("Upload File", variant: "primary")}
          </form>
        UPLOAD
      end}

      #{otto_card("User Profile Input Validation") do
        <<~PROFILE
          <form method="post" action="/profile" class="otto-form">
            #{csrf_tag}
            <label>Name:</label>
            #{otto_input("name", placeholder: "Your name", required: true)}

            <label>Email:</label>
            #{otto_input("email", type: "email", placeholder: "your@email.com", required: true)}

            <label>Bio:</label>
            #{otto_textarea("bio", placeholder: "Tell us about yourself...")}

            #{otto_button("Update Profile", variant: "primary")}
          </form>
        PROFILE
      end}

      #{otto_card("Security Information") do
        <<~INFO
          <h3>Security Features Active:</h3>
          <ul>
            <li><strong>CSRF Protection:</strong> All forms include CSRF tokens</li>
            <li><strong>Input Validation:</strong> Server-side validation with length limits</li>
            <li><strong>XSS Prevention:</strong> HTML escaping for all user inputs</li>
            <li><strong>Security Headers:</strong> Comprehensive header security policy</li>
          </ul>

          <p class="otto-mt-md">
            <strong>Test XSS Protection:</strong> Try entering
            #{otto_code_block('<script>alert("XSS")</script>', 'html')}
            in any form field to see input sanitization in action.
          </p>

          <p class="otto-mt-md">
            #{otto_link("View Request Headers", "/headers")}
          </p>
        INFO
      end}
    HTML

    res.body = otto_page(content, "Otto Security Features")
  end

  def receive_feedback
    begin
      message = req.params['message']

      if respond_to?(:validate_input)
        safe_message = validate_input(message, max_length: 1000, allow_html: false)
      else
        safe_message = message.to_s.strip
        raise "Message too long" if safe_message.length > 1000
      end

      if safe_message.empty?
        content = otto_alert("error", "Validation Error", "Message cannot be empty.")
      else
        content = <<~HTML
          #{otto_alert("success", "Feedback Received", "Thank you for your feedback!")}

          #{otto_card("Your Message") do
            otto_code_block(safe_message, 'text')
          end}
        HTML
      end

    rescue Otto::Security::ValidationError => e
      content = otto_alert("error", "Security Validation Failed", e.message)
    rescue => e
      content = otto_alert("error", "Processing Error", "An error occurred processing your request.")
    end

    content += "<p class=\"otto-mt-lg\">#{otto_link("← Back to form", "/")}</p>"
    res.body = otto_page(content, "Feedback Response")
  end

  def upload_file
    begin
      uploaded_file = req.params['upload_file']

      if uploaded_file.nil? || uploaded_file.empty?
        content = otto_alert("error", "Upload Error", "No file was selected.")
      else
        filename = uploaded_file[:filename] rescue uploaded_file.original_filename rescue 'unknown'

        if respond_to?(:sanitize_filename)
          safe_filename = sanitize_filename(filename)
        else
          safe_filename = File.basename(filename.to_s).gsub(/[^\w\-_\.]/, '_')
        end

        file_info = {
          "Original filename" => filename,
          "Sanitized filename" => safe_filename,
          "Content type" => uploaded_file[:type] || 'unknown',
          "Security status" => "File validated and processed safely"
        }

        info_html = file_info.map { |key, value|
          "<p><strong>#{key}:</strong> #{escape_html(value)}</p>"
        }.join

        content = <<~HTML
          #{otto_alert("success", "File Upload Successful", "File processed and validated successfully!")}

          #{otto_card("File Information") do
            info_html
          end}

          <div class="otto-alert otto-alert-info">
            <h3 class="otto-alert-title">Demo Notice</h3>
            <p class="otto-alert-message">This is a demonstration - files are validated but not permanently stored.</p>
          </div>
        HTML
      end

    rescue Otto::Security::ValidationError => e
      content = otto_alert("error", "File Validation Failed", e.message)
    rescue => e
      content = otto_alert("error", "Upload Error", "An error occurred during file upload.")
    end

    content += "<p class=\"otto-mt-lg\">#{otto_link("← Back to form", "/")}</p>"
    res.body = otto_page(content, "Upload Response")
  end

  def update_profile
    begin
      name = req.params['name']
      email = req.params['email']
      bio = req.params['bio']

      if respond_to?(:validate_input)
        safe_name = validate_input(name, max_length: 100)
        safe_email = validate_input(email, max_length: 255)
        safe_bio = validate_input(bio, max_length: 500, allow_html: false)
      else
        safe_name = name.to_s.strip[0..99]
        safe_email = email.to_s.strip[0..254]
        safe_bio = bio.to_s.strip[0..499]
      end

      unless safe_email.match?(/\A[^@\s]+@[^@\s]+\z/)
        raise Otto::Security::ValidationError, "Invalid email format"
      end

      profile_data = {
        "Name" => safe_name,
        "Email" => safe_email,
        "Bio" => safe_bio,
        "Updated" => Time.now.strftime("%Y-%m-%d %H:%M:%S UTC")
      }

      profile_html = profile_data.map { |key, value|
        "<p><strong>#{key}:</strong> #{escape_html(value)}</p>"
      }.join

      content = <<~HTML
        #{otto_alert("success", "Profile Updated", "Your profile has been updated successfully!")}

        #{otto_card("Profile Data") do
          profile_html
        end}
      HTML

    rescue Otto::Security::ValidationError => e
      content = otto_alert("error", "Profile Validation Failed", e.message)
    rescue => e
      content = otto_alert("error", "Update Error", "An error occurred updating your profile.")
    end

    content += "<p class=\"otto-mt-lg\">#{otto_link("← Back to form", "/")}</p>"
    res.body = otto_page(content, "Profile Update")
  end

  def show_headers
    res.headers['content-type'] = 'application/json; charset=utf-8'

    safe_headers = {}
    req.env.each do |key, value|
      if key.start_with?('HTTP_') || %w[REQUEST_METHOD PATH_INFO QUERY_STRING].include?(key)
        safe_headers[key] = value.to_s[0..200]
      end
    end

    response_data = {
      message: "Request headers analysis (filtered for security)",
      client_ip: req.respond_to?(:client_ipaddress) ? req.client_ipaddress : req.ip,
      secure_connection: req.respond_to?(:secure?) ? req.secure? : false,
      timestamp: Time.now.utc.iso8601,
      headers: safe_headers,
      security_analysis: {
        csrf_protection: respond_to?(:csrf_token_valid?) ? "Active" : "Basic",
        content_security: "Headers validated and filtered",
        xss_protection: "HTML escaping enabled"
      }
    }

    require 'json'
    res.body = JSON.pretty_generate(response_data)
  end

  def not_found
    res.status = 404
    content = otto_alert("error", "Page Not Found", "The requested page could not be found.")
    content += "<p>#{otto_link("← Back to home", "/")}</p>"
    res.body = otto_page(content, "404 - Not Found")
  end

  def server_error
    res.status = 500
    error_id = req.env['otto.error_id'] || SecureRandom.hex(8)
    content = otto_alert("error", "Server Error", "An internal server error occurred.")
    content += "<p><small>Error ID: #{escape_html(error_id)}</small></p>"
    content += "<p>#{otto_link("← Back to home", "/")}</p>"
    res.body = otto_page(content, "500 - Server Error")
  end
end
