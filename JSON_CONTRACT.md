# JSON-контракты для Express/Zod

Все объекты валидируются бэкендом до сохранения. SQL не выполняет код/имена таблиц из LLM. JSON передаётся драйверу через JSON.stringify. Неизвестные фильтры → null, флаги → false, коллекции → [].

## 1. Разбор рассказа: recommendation_runs.parsed_profile

```json
{
  "skills": ["C#", "SQL"],
  "interests": ["разработка сервисов"],
  "education": "колледж",
  "search": "",
  "city": null,
  "region_name": null,
  "country_code": null,
  "region_code": null,
  "specialisation": null,
  "typical_positions": ["Программист"],
  "include_remote": false,
  "work_format": "remote",
  "employment_type": "full_time",
  "schedule_type": "five_two",
  "contract_type": null,
  "min_salary": 60000,
  "currency": "RUB",
  "salary_period": "month",
  "salary_gross": null,
  "experience_months": 0,
  "only_no_experience": true,
  "require_all_required": false
}
```

skills сопоставляется с общим справочником и полностью заменяет user_skills для нового полного рассказа. interests/education сохраняются как сведения для LLM-группировки; сами по себе они не являются квалификационным допуском к профессии.

Остальные ключи соответствуют параметрам Q03. typical_positions берётся из контролируемых названий Q14/каталога; непустой массив передаётся в typical_positions_json как JSON, пустой → SQL NULL. Строки города/специализации и региональные коды должны соответствовать данным каталога, не произвольным придуманным LLM значениям.

Форматы: work_format=onsite/remote/hybrid/unknown; employment_type=full_time/part_time/internship/unknown; schedule_type=five_two/six_one/shift/flexible/other/unknown; contract_type=permanent/fixed_term/unknown. NULL отключает фильтр. Полный день не означает бессрочный договор. Не заставляйте unknown совпадать с конкретным условием; не включайте строгий permanent по умолчанию, если источник не сообщает срок.

salary_period=hour/shift/day/week/month/year/unknown. Зарплата сравнивается только в одной валюте и за один подтверждённый период. salary_gross=true до налога, false на руки, NULL не уточнено. Неизвестный стаж NULL, нулевой стаж только при явном отсутствии опыта. Строгие фильтры могут исключить вакансии с неуказанными условиями.

user_id берётся из авторизованного QA03. Пагинация проверяется API, максимум 50 кандидатов для LLM-группировки и 100 для каталога. Нет свободных часов, календаря и полей availability/time_zone.

## 2. Упрощение вакансии: vacancy_ai_summaries.result_json

```json
{
  "simpleTitle": "Продавец-консультант",
  "whatYouDo": ["Помогать покупателям", "Следить за товарами"],
  "requirements": ["Уметь общаться с клиентами"],
  "conditions": ["Полный день", "Сменный график"],
  "beginnerFriendly": true
}
```

Zod проверяет непустой заголовок, массивы строк с разумными ограничениями длины и boolean. beginnerFriendly — поясняющая оценка текста, а не гарантия найма или отсутствия квалификационных требований. Не добавлять зарплату/условия, отсутствующие в оригинале. SQL проверяет основные ключи и типы, но не семантическую достоверность.

## 3. Группировка кандидатов

```json
{
  "directions": [
    {
      "title": "Разработка на C#",
      "whySuitable": "Вы указали C# и SQL, они встречаются в этих вакансиях.",
      "vacancyIds": ["2", "17"]
    }
  ]
}
```

ID — строки. Каждый vacancyId обязан входить в кандидаты данного recommendation_run. До 5 направлений, обычно 3–5 при достаточном количестве данных; при малой выборке разрешено меньше. При нуле кандидатов вернуть пустой список и понятное result_note. Нельзя придумывать отсутствующие вакансии или гарантировать пригодность по медицинским/квалификационным требованиям только из интересов.

SQL QP06/QP07 сохраняет направления и ссылки, QP08 завершает запуск. Сохранение групп/ссылок выполняется одной транзакцией. Составные FK дополнительно не пропускают вакансию вне кандидатов этого run.
