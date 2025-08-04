require_relative '../../lib/otto'
require_relative 'app'

# Configure Otto with locale support and security features
app = Otto.new("./routes", {
  # Locale configuration
  locale_config: {
    available_locales: {
      'en' => 'English',
      'es' => 'Spanish',
      'fr' => 'French'
    },
    default_locale: 'en'
  },

  # Security features
  csrf_protection: true,
  request_validation: true,
  trusted_proxies: ['127.0.0.1', '::1']
})

# Enable additional security headers
app.enable_csp_with_nonce!(debug: true)
app.enable_frame_protection!('SAMEORIGIN')

run app
