require 'dotenv/load'
require 'sinatra/base'
require 'json'
require 'yaml'
require 'net/http'
require 'uri'
require 'logger'
require 'openssl'

# Версия приложения
VERSION = '1.0.0'

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
  
  # Настройка логгера
  configure do
    enable :logging
    log_file = File.join(__dir__, 'unfurl.log')
    $logger = Logger.new(log_file)
    $logger.level = ENV['RACK_ENV'] == 'development' ? Logger::DEBUG : Logger::INFO
    $logger.formatter = proc do |severity, datetime, progname, msg|
      "[#{datetime}] #{severity}: #{msg}\n"
    end
    
    $logger.info "Запуск бота Pachca Unfurling v#{VERSION} в режиме #{ENV['RACK_ENV']}"
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
    
    unless signature_header && webhook_secret
      $logger.warn "Отсутствует подпись или секрет вебхука"
      return false
    end
    
    # Вычисляем HMAC-SHA256 от тела запроса
    hmac = OpenSSL::HMAC.hexdigest('SHA256', webhook_secret, request_body)
    expected_signature = "sha256=#{hmac}"
    
    # Проверяем подпись
    if signature_header == expected_signature
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
  
  # Эндпоинт для проверки работоспособности
  get '/health' do
    content_type :json
    { 
      status: 'ok', 
      version: VERSION,
      services: SERVICE_CONFIG['services'].map { |s| s['name'] }
    }.to_json
  end

  # Универсальный POST endpoint для unfurl
  post '/unfurl' do
    content_type :json
    
    # Безопасно получаем тело запроса
    request_body = request.body.read.to_s
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
        req['Authorization'] = "Bearer #{ENV['UNFURL_BOT_TOKEN']}"
        req['Content-Type'] = 'application/json'
        req.body = { link_previews: previews }.to_json
        
        $logger.info "Отправка превью в Пачку для ссылок: #{previews.keys.join(', ')}"
        
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

  # ===== Пример обработчика для Notion =====
  def self.notion_handler(url)
    notion_token = ENV['NOTION_TOKEN']
    raise 'No NOTION_TOKEN in ENV' unless notion_token
    page_id = url[/[0-9a-f]{32}/i]
    raise 'Notion page ID not found in URL' unless page_id
    uuid = page_id.scan(/.{8}|.{4}|.{4}|.{4}|.{12}/).join('-')
    uri = URI("https://api.notion.com/v1/pages/#{uuid}")
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{notion_token}"
    req['Notion-Version'] = '2022-06-28'
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "Notion API error: #{res.code}" unless res.code == '200'
    data = JSON.parse(res.body)
    title = data.dig('properties', 'title', 'title', 0, 'plain_text') || 'Notion Page'
    {
      title: title,
      url: url,
      description: 'Notion page preview',
      icon: '📝'
    }
  end

  # ===== Обработчик для Jira =====
  def self.jira_handler(url)
    jira_email = ENV['JIRA_EMAIL']
    jira_token = ENV['JIRA_API_TOKEN']
    raise 'No JIRA_EMAIL or JIRA_API_TOKEN in ENV' unless jira_email && jira_token
    match = url.match(%r{https://([\w\.-]+)/browse/([A-Z0-9\-]+)})
    raise 'Invalid Jira URL' unless match
    domain = match[1]
    issue_key = match[2]
    api_url = "https://#{domain}/rest/api/3/issue/#{issue_key}"
    uri = URI(api_url)
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(jira_email, jira_token)
    req['Accept'] = 'application/json'
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "Jira API error: #{res.code}" unless res.code == '200'
    data = JSON.parse(res.body)
    summary = data.dig('fields', 'summary') || 'Jira Issue'
    status = data.dig('fields', 'status', 'name') || 'Unknown'
    {
      title: "#{issue_key}: #{summary}",
      url: url,
      description: "Status: #{status}",
      icon: '📋'
    }
  end

  # ===== Обработчик для Яндекс.Трекера =====
  def self.yatracker_handler(url)
    yatracker_token = ENV['YATRACKER_TOKEN']
    raise 'No YATRACKER_TOKEN in ENV' unless yatracker_token
    match = url.match(%r{tracker\.yandex\.ru/([A-Z0-9\-_]+)})
    raise 'Invalid Yandex Tracker URL' unless match
    issue_key = match[1]
    api_url = "https://api.tracker.yandex.net/v2/issues/#{issue_key}"
    uri = URI(api_url)
    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "OAuth #{yatracker_token}"
    req['Accept'] = 'application/json'
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
    raise "Yandex Tracker API error: #{res.code}" unless res.code == '200'
    data = JSON.parse(res.body)
    summary = data['summary'] || 'Yandex Tracker Issue'
    status = data.dig('status', 'display') || 'Unknown'
    assignee = data.dig('assignee', 'display') || 'Unassigned'
    {
      title: "#{issue_key}: #{summary}",
      url: url,
      description: "Status: #{status}, Assignee: #{assignee}",
      icon: '🎫'
    }
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

  run! if app_file == $0
end
