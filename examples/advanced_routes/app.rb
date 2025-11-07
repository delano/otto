# examples/advanced_routes/app.rb

# Application Loader

# Controllers
require_relative 'app/controllers/routes_app'
require_relative 'app/controllers/handlers/async'
require_relative 'app/controllers/handlers/dynamic'
require_relative 'app/controllers/handlers/static'
require_relative 'app/controllers/modules/auth'
require_relative 'app/controllers/modules/transformer'
require_relative 'app/controllers/modules/validator'
require_relative 'app/controllers/v2/admin'
require_relative 'app/controllers/v2/config'
require_relative 'app/controllers/v2/settings'

# Logic Classes
require_relative 'app/logic/admin/logic/manager'
require_relative 'app/logic/admin/panel'
require_relative 'app/logic/analytics_processor'
require_relative 'app/logic/complex/business/handler'
require_relative 'app/logic/data_logic'
require_relative 'app/logic/data_processor'
require_relative 'app/logic/input_validator'
require_relative 'app/logic/nested/feature/logic'
require_relative 'app/logic/reports_generator'
require_relative 'app/logic/simple_logic'
require_relative 'app/logic/system/config/manager'
require_relative 'app/logic/test_logic'
require_relative 'app/logic/transform_logic'
require_relative 'app/logic/upload_logic'
require_relative 'app/logic/v2/logic/dashboard'
require_relative 'app/logic/v2/logic/processor'
