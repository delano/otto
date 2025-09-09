require_relative '../../lib/otto'
require_relative 'app'

# Global configuration for all Otto instances
Otto.configure do |opts|
  opts.available_locales = {
    'en' => 'English',
    'es' => 'Spanish',
    'fr' => 'French',
  }
  opts.default_locale = 'en'
end

# Configure Otto with security features
app = Otto.new('./routes', {
                 # Security features
                 csrf_protection: true,
  request_validation: true,
  trusted_proxies: ['127.0.0.1', '::1'],
               })

# Enable additional security headers
app.enable_csp_with_nonce!(debug: true)
app.enable_frame_protection!('SAMEORIGIN')

run app
