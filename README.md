# Pachca Unfurling Bot (Ruby)

Универсальный бот для разворачивания ссылок (unfurling) в Пачке с поддержкой различных сервисов (Notion, Jira, Trello и др.).

## Возможности

- Автоматическое разворачивание ссылок в Пачке
- Поддержка различных сервисов: Notion, Jira, Яндекс.Трекер, Trello
- Простое добавление новых обработчиков ссылок
- Проверка подписи запросов от Пачки для безопасности
- Подробное логирование для отладки

## Быстрый старт

### Локальный запуск

1. Клонируйте репозиторий и перейдите в папку:
   ```sh
   git clone https://github.com/your-username/pachca-unfurling-ruby.git
   cd pachca-unfurling-ruby
   ```

2. Создайте файл `.env` на основе `.env.example` и заполните необходимые переменные:
   ```sh
   cp .env.example .env
   # Отредактируйте .env и добавьте ваши токены
   ```

3. Установите зависимости:
   ```sh
   bundle install
   ```

4. Запустите сервер:
   ```sh
   bundle exec ruby app.rb
   ```

5. Сервер будет доступен по адресу http://localhost:4567

### Запуск с использованием Docker

1. Клонируйте репозиторий и создайте файл `.env`
2. Соберите и запустите контейнер:
   ```sh
   docker-compose up -d
   ```

## Деплой на облачные платформы

### Replit

1. Создайте новый Repl, выбрав шаблон Ruby
2. Загрузите все файлы проекта
3. Добавьте переменные окружения в секрете Replit
4. Запустите проект

### Vercel

Для деплоя на Vercel, используйте следующую конфигурацию в `vercel.json`:

```json
{
  "version": 2,
  "builds": [
    { "src": "app.rb", "use": "@vercel/ruby" }
  ],
  "routes": [
    { "src": "/(.*)", "dest": "/app.rb" }
  ]
}
```

### Zeabur

1. Создайте новый проект в Zeabur
2. Подключите репозиторий с кодом
3. Настройте переменные окружения
4. Разверните приложение

## Настройка в Пачке

1. В настройках Пачки добавьте новую интеграцию для unfurling
2. Укажите URL вашего развернутого сервера
3. Получите и сохраните токен и секрет вебхука в переменных окружения

## Добавление новых обработчиков ссылок

1. Добавьте новый обработчик в `app.rb`:

```ruby
def self.your_service_handler(url)
  # Получение токена из переменных окружения
  api_token = ENV['YOUR_SERVICE_TOKEN']
  raise 'No YOUR_SERVICE_TOKEN in ENV' unless api_token
  
  # Парсинг URL для получения идентификатора
  match = url.match(%r{your-service\.com/([a-zA-Z0-9]+)})
  raise 'Invalid URL format' unless match
  item_id = match[1]
  
  # Запрос к API сервиса
  api_url = "https://api.your-service.com/items/#{item_id}"
  uri = URI(api_url)
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{api_token}"
  req['Accept'] = 'application/json'
  
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  raise "API error: #{res.code}" unless res.code == '200'
  
  # Обработка ответа
  data = JSON.parse(res.body)
  title = data['title'] || 'Item Title'
  description = data['description'] || 'No description'
  
  # Возвращаем результат
  {
    title: title,
    url: url,
    description: description,
    icon: '📄'
  }
end
```

2. Добавьте сервис в `services.yml`:

```yaml
- name: your_service
  match: "your-service\\.com"
  handler: "your_service_handler"
```

3. Добавьте переменную окружения в `.env`:

```
YOUR_SERVICE_TOKEN=your_api_token_here
```

## Безопасность

- Все токены хранятся только в переменных окружения, не в коде
- Проверка подписи запросов от Пачки
- Используйте HTTPS при деплое на продакшн
- Регулярно обновляйте зависимости

## Логирование и отладка

Логи сохраняются в файл `unfurl.log`. Для более подробного логирования установите переменную окружения `RACK_ENV=development`.

## Пример запроса

```sh
curl -X POST http://localhost:4567/unfurl \
  -H 'Authorization: Bearer <UNFURL_BOT_TOKEN>' \
  -H 'Content-Type: application/json' \
  -d '{
    "message_id": "123456",
    "links": [
      {"url": "https://www.notion.so/your-page-id"}
    ]
  }'
```

## Лицензия

MIT

# pachca_unfurl_public
Бот для разворачивания ссылок из рабочих сервисов в мессенджере Пачка
