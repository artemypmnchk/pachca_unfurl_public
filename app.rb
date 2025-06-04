# encoding: utf-8
require 'dotenv/load'
require 'sinatra/base'
require 'json'
require 'yaml'
require 'net/http'
require 'uri'
require 'logger'
require 'openssl'

# Версия приложения
VERSION = '1.1.0'
API_VERSION = 'v1'

# Настройки окружения
ENV['RACK_ENV'] = ENV['RACK_ENV'] || 'development'

# В режиме разработки отключаем проверку хостов
if ENV['RACK_ENV'] == 'development'
  ENV['RACK_ALLOW_ALL_HOSTS'] = 'true'
end

class UnfurlApp < Sinatra::Base
  # Основные настройки
  set :port, ENV['PORT'] || 4567
  set :bind, '0.0.0.0'
  set :show_exceptions, ENV['RACK_ENV'] == 'development'
  set :public_folder, File.dirname(__FILE__) + '/public'
  
  # Настройки защиты
  if ENV['RACK_ENV'] == 'development'
    # В режиме разработки отключаем некоторые защиты
    set :protection, except: [:host_authorization]
    set :hosts, nil
  else
    # В продакшне включаем защиты, но разрешаем CORS
    set :protection, :except => [:json_csrf]
  end
  
  # Настройки CORS
  configure do
    before do
      response.headers['Access-Control-Allow-Origin'] = '*'
      response.headers['Access-Control-Allow-Methods'] = 'POST, GET, OPTIONS'
      response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization, Pachca-Signature'
    end
    
    # Обработка OPTIONS запросов для CORS
    options "*" do
      response.headers["Allow"] = "GET, POST, OPTIONS"
      200
    end
  end
  
  # Инициализация логгера
  configure do
    # Настройка логирования в файл с ротацией (10 файлов по 1MB)
    log_file = ENV['LOG_FILE'] || 'unfurl.log'
    
    if ENV['RACK_ENV'] == 'development'
      # В режиме разработки логируем и в файл, и в консоль
      log_outputs = [STDOUT, log_file]
      log_level = Logger::DEBUG
    else
      # В продакшене только в файл
      log_outputs = [log_file]
      log_level = Logger::INFO
    end
    
    # Создаем мультилоггер
    $logger = Logger.new(log_outputs.first, 10, 1024000)
    
    # Если нужно логировать в несколько мест
    if log_outputs.size > 1
      log_outputs[1..-1].each do |output|
        $logger.extend(Module.new {
          define_method(:add) do |severity, message = nil, progname = nil|
            super(severity, message, progname)
            file_logger = Logger.new(output, 10, 1024000)
            file_logger.level = log_level
            file_logger.formatter = proc do |sev, datetime, prog, msg|
              "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{sev}: #{msg}\n"
            end
            file_logger.add(severity, message, progname)
          end
        })
      end
    end
    
    $logger.level = log_level
    $logger.formatter = proc do |severity, datetime, progname, msg|
      "[#{datetime.strftime('%Y-%m-%d %H:%M:%S')}] #{severity}: #{msg}\n"
    end
    
    $logger.info "Запуск бота Pachca Unfurling v#{VERSION} в режиме #{ENV['RACK_ENV']}"
    $logger.info "Логирование настроено в: #{log_outputs.join(', ')}"
  end
  
  # Обработка ошибок
  error do
    err = env['sinatra.error']
    $logger.error "Ошибка: #{err.class} - #{err.message}\n#{err.backtrace.join("\n")}"
    content_type :json
    status 500
    { error: 'Внутренняя ошибка сервера', message: err.message }.to_json
  end
  
  # Проверка подписи Пачки
  def verify_pachca_signature(request_body)
    # В режиме разработки можно отключить проверку
    return true if ENV['RACK_ENV'] == 'development' && ENV['SKIP_SIGNATURE_CHECK'] == 'true'
    
    signature_header = request.env['HTTP_PACHCA_SIGNATURE']
    webhook_secret = ENV['PACHCA_WEBHOOK_SECRET']
    
    # Расширенное логирование для отладки
    $logger.info "Проверка подписи: Получен заголовок подписи: #{signature_header || 'отсутствует'}"
    $logger.info "Проверка подписи: Секрет вебхука #{webhook_secret ? 'присутствует' : 'отсутствует'}"
    
    unless signature_header && webhook_secret
      $logger.warn "Отсутствует подпись или секрет вебхука"
      return false
    end
    
    # Вычисляем HMAC-SHA256 от тела запроса
    hmac = OpenSSL::HMAC.hexdigest('SHA256', webhook_secret, request_body)
    
    # Расширенное логирование для отладки
    $logger.info "Проверка подписи: Ожидаемая подпись: #{hmac}"
    $logger.info "Проверка подписи: Полученная подпись: #{signature_header}"
    
    # Проверяем подпись
    if signature_header == hmac
      $logger.info "Подпись Пачки верифицирована"
      return true
    else
      $logger.warn "Неверная подпись Пачки"
      return false
    end
  end

  # Загрузка конфигурации сервисов
  SERVICE_CONFIG = YAML.load_file(File.join(__dir__, 'services.yml'))

  # Проверка токена Пачки
  BEARER_TOKEN = ENV['UNFURL_BOT_TOKEN']
  
  # Корневой маршрут для проверки работоспособности
  get '/' do
    content_type :json
    { status: 'ok', version: VERSION }.to_json
  end
  
  # Эндпоинт health check для мониторинга
  get '/health' do
    content_type :json
    
    # Проверка наличия необходимых переменных окружения
    env_status = {}
    required_env = ['UNFURL_BOT_TOKEN', 'UNFURL_SIGNING_SECRET']
    
    # Проверяем токены для каждого сервиса из services.yml
    begin
      services = SERVICE_CONFIG['services']
      services.each do |service|
        handler_name = service['handler']
        if handler_name == 'trello_handler'
          required_env << 'TRELLO_KEY' << 'TRELLO_TOKEN'
        elsif handler_name == 'kaiten_handler'
          required_env << 'KAITEN_TOKEN'
        end
      end
    rescue => e
      $logger.error "Ошибка при загрузке services.yml: #{e.message}"
    end
    
    # Проверяем наличие всех переменных
    required_env.uniq.each do |env_var|
      env_status[env_var] = ENV[env_var] ? true : false
    end
    
    # Проверка доступа к файлу логов
    log_file = ENV['LOG_FILE'] || 'unfurl.log'
    log_status = File.writable?(log_file) || File.writable?(File.dirname(log_file))
    
    # Формируем статус
    status_code = env_status.values.all? && log_status ? 200 : 503
    
    status status_code
    {
      status: status_code == 200 ? 'ok' : 'error',
      version: VERSION,
      environment: ENV['RACK_ENV'],
      timestamp: Time.now.iso8601,
      services: SERVICE_CONFIG['services'].map { |s| s['name'] },
      checks: {
        environment_variables: env_status,
        log_file_writable: log_status
      }
    }.to_json
  end

  # Универсальный POST endpoint для unfurl
  post '/unfurl' do
    content_type :json
    process_unfurl_request(request)
  end
  
  # Версионированный endpoint для unfurl
  post "/#{API_VERSION}/unfurl" do
    content_type :json
    process_unfurl_request(request)
  end
  
  # Общая логика обработки unfurl запросов
  def process_unfurl_request(request)
    raw_body = request.body.read
    request_body = raw_body.dup.force_encoding('UTF-8')
    unless request_body.valid_encoding?
      request_body = raw_body.encode('UTF-8', 'binary', invalid: :replace, undef: :replace, replace: '?')
    end
    request.body.rewind
    
    # Логируем запрос
    $logger.info "Получен запрос на /unfurl"
    $logger.debug "Тело запроса: #{request_body}"
    
    begin
      # Проверяем подпись Пачки
      unless verify_pachca_signature(request_body)
        $logger.warn "Запрос отклонен: неверная подпись"
        halt 401, { error: 'Неверная подпись' }.to_json
      end
      
      # Парсим JSON
      data = JSON.parse(request_body)
      
      # Получаем необходимые данные
      message_id = data['message_id']
      links = data['links']
      
      unless message_id && links
        $logger.warn "Отсутствует message_id или links в запросе"
        halt 400, { error: 'Не указан message_id или links' }.to_json
      end

      # Собираем превью для каждой ссылки
      previews = {}
      links.each do |link|
        url = link['url']
        $logger.info "Обработка ссылки: #{url}"
        
        # Находим подходящий обработчик
        service = SERVICE_CONFIG['services'].find { |s| url.match(/#{s['match']}/i) }
        
        unless service
          $logger.info "Не найден обработчик для ссылки: #{url}"
          next
        end
        
        begin
          $logger.info "Используем обработчик: #{service['handler']} для #{url}"
          
          # Вызываем метод класса UnfurlApp
          handler_method = service['handler']
          result = UnfurlApp.send(handler_method, url)
          
          # Приводим к формату Пачки
          previews[url] = {
            title: result[:title],
            description: result[:description],
            image_url: result[:image_url]
          }.compact
          
          $logger.info "Успешно получено превью для #{url}: #{result[:title]}"
        rescue => e
          $logger.error "Ошибка при обработке #{url}: #{e.message}\n#{e.backtrace.join("\n")}"
          previews[url] = { 
            title: "Ошибка обработки ссылки", 
            description: "Не удалось получить информацию: #{e.message.split("\n").first}"
          }
        end
      end
      
      # Если не удалось получить ни одного превью
      if previews.empty?
        $logger.warn "Не удалось получить ни одного превью"
        return { status: "no_previews", message: "Не удалось получить превью ни для одной ссылки" }.to_json
      end
      
      # Отправляем превью в Пачку
      begin
        api_url = "https://api.pachca.com/api/shared/v1/messages/#{message_id}/link_previews"
        uri = URI(api_url)
        req = Net::HTTP::Post.new(uri)
        
        # Проверяем наличие токена
        token = ENV['UNFURL_BOT_TOKEN']
        if token.nil? || token.empty?
          $logger.error "ОШИБКА: Отсутствует UNFURL_BOT_TOKEN в переменных окружения"
          return { status: "error", message: "Отсутствует токен для API Пачки" }.to_json
        end
        
        req['Authorization'] = "Bearer #{token}"
        req['Content-Type'] = 'application/json'
        req.body = { link_previews: previews }.to_json
        
        $logger.info "Отправка превью в Пачку для ссылок: #{previews.keys.join(', ')}"
        $logger.info "Тело запроса: #{req.body}"
        
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 5  # Таймаут соединения
        http.read_timeout = 10 # Таймаут чтения
        
        res = http.request(req)
        
        $logger.info "Ответ от Пачки: #{res.code}"
        
        if res.code.to_i >= 400
          $logger.error "Ошибка при отправке в Пачку: #{res.code} #{res.body}"
          return { 
            status: "error", 
            code: res.code, 
            message: "Ошибка при отправке превью в Пачку"
          }.to_json
        end
        
        { 
          status: "success", 
          message: "Превью успешно отправлены", 
          urls: previews.keys
        }.to_json
      rescue => e
        $logger.error "Ошибка при отправке в Пачку: #{e.message}\n#{e.backtrace.join("\n")}"
        halt 500, { 
          error: "Ошибка отправки в Пачку", 
          message: e.message 
        }.to_json
      end
    rescue JSON::ParserError => e
      $logger.error "Ошибка парсинга JSON: #{e.message}"
      halt 400, { error: 'Неверный формат JSON' }.to_json
    rescue StandardError => e
      $logger.error "Неожиданная ошибка: #{e.message}\n#{e.backtrace.join("\n")}"
      halt 500, { error: 'Внутренняя ошибка сервера' }.to_json
    end
  end

  # ===== Обработчик для Trello =====
  def self.trello_handler(url)
    $logger.info "Обработка Trello ссылки: #{url}"
    
    # Проверка наличия токенов
    trello_key = ENV['TRELLO_KEY']
    trello_token = ENV['TRELLO_TOKEN']
    unless trello_key && trello_token
      $logger.error "Отсутствуют TRELLO_KEY или TRELLO_TOKEN в переменных окружения"
      raise 'No TRELLO_KEY or TRELLO_TOKEN in ENV' 
    end
    
    # Парсинг ID карточки
    match = url.match(%r{trello\.com/c/([a-zA-Z0-9]+)})
    unless match
      $logger.error "Неверный формат URL Trello: #{url}"
      raise 'Invalid Trello card URL' 
    end
    
    card_id = match[1]
    $logger.info "Получен ID карточки Trello: #{card_id}"
    
    # Запрос к API Trello
    api_url = "https://api.trello.com/1/cards/#{card_id}?key=#{trello_key}&token=#{trello_token}"
    uri = URI(api_url)
    req = Net::HTTP::Get.new(uri)
    req['Accept'] = 'application/json'
    
    $logger.info "Отправка запроса к API Trello"
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    
    unless res.code == '200'
      $logger.error "Ошибка API Trello: #{res.code} - #{res.body}"
      raise "Trello API error: #{res.code}" 
    end
    
    # Обработка ответа
    data = JSON.parse(res.body)
    name = data['name'] || 'Trello Card'
    desc = data['desc'] || ''
    url = data['shortUrl'] || url
    
    $logger.info "Успешно получены данные карточки Trello: #{name}"
    {
      title: name,
      url: url,
      description: desc.empty? ? 'No description' : desc,
      icon: '🟩'
    }
  end

  # ===== Обработчик для Kaiten =====
  def self.kaiten_handler(url)
    $logger.info "Обработка Kaiten ссылки: #{url}"
    
    # Проверка наличия токена
    kaiten_token = ENV['KAITEN_TOKEN']
    unless kaiten_token
      $logger.error "Отсутствует KAITEN_TOKEN в переменных окружения"
      raise 'No KAITEN_TOKEN in ENV' 
    end
    
    # Парсинг ID карточки
    match = url.match(%r{kaiten\.ru/.*?/card/([0-9]+)})
    unless match
      $logger.error "Неверный формат URL Kaiten: #{url}"
      raise 'Invalid Kaiten card URL' 
    end
    
    card_id = match[1]
    $logger.info "Получен ID карточки Kaiten: #{card_id}"
    
    # Извлечение домена из URL
    domain_match = url.match(%r{https?://([^/]+)})
    domain = domain_match ? domain_match[1] : 'kaiten.ru'
    
    # Запрос к API Kaiten
    api_url = "https://#{domain}/api/v1/cards/#{card_id}"
    uri = URI(api_url)
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{kaiten_token}"
    req['Accept'] = 'application/json'
    
    $logger.info "Отправка запроса к API Kaiten"
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    
    unless res.code == '200'
      $logger.error "Ошибка API Kaiten: #{res.code} - #{res.body}"
      raise "Kaiten API error: #{res.code}" 
    end
    
    # Обработка ответа
    data = JSON.parse(res.body)
    title = data['title'] || 'Kaiten Card'
    description = data['description'] || ''
    
    # Дополнительная информация
    status = ''
    if data['state']
      state_map = { 1 => 'В очереди', 2 => 'В работе', 3 => 'Готово' }
      status = state_map[data['state']] || 'Неизвестно'
    end
    
    # Формирование описания
    description_text = description.empty? ? '' : description
    if !status.empty?
      description_text += description_text.empty? ? "Статус: #{status}" : "\nСтатус: #{status}"
    end
    
    $logger.info "Успешно получены данные карточки Kaiten: #{title}"
    {
      title: title,
      url: url,
      description: description_text.empty? ? 'Нет описания' : description_text,
      icon: '📊'
    }
  end

  run! if app_file == $0
end
