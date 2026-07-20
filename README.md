# PhotosPurge

**A solution for Google account storage overflow.**

If you've ever hit the 15 GB limit across Gmail, Drive, and Photos or needed to move everything from one Google account to another. This tool does it for you. PhotosPurge is a self-hosted Django application that automates bulk operations against Google's APIs using background workers. It migrates photo libraries, transfers Drive files with folder structure intact, and mass-deletes emails by category.

```
Tested on Python 3.10 | Django 4.x | Celery 5.x | Redis 7.x
```

---

## Table of Contents

- [Background](#background)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Running the Application](#running-the-application)
- [How It Works](#how-it-works)
- [Project Structure](#project-structure)
- [Models](#models)
- [Token Refresh Strategy](#token-refresh-strategy)
- [Known Limitations](#known-limitations)
- [Contributing](#contributing)
- [Acknowledgements](#acknowledgements)

---

## Background

Google gives every account 15 GB of free storage shared across Gmail, Drive, and Photos. Once that fills up, you either pay for more or start cleaning. PhotosPurge was built to handle the cleaning side and to make switching Google accounts less painful by migrating everything instead of starting fresh.

The main challenge is that Google's APIs rate-limit aggressively, access tokens expire after 60 minutes, and large libraries can take hours to process. PhotosPurge handles all of this: token refresh happens proactively before each batch, tasks run in the background via Celery, and progress is tracked live in the database so you can check in at any time.

---

## Features

- Migrate an entire Google Photos library between two accounts, page by page
- Migrate Google Drive files and folders between accounts, preserving folder hierarchy
- Per-file failure tracking on Drive migrations, one bad file does not stop the job
- Bulk delete Gmail emails by category (Promotions, Social, Updates, etc.)
- Recover all emails from Gmail Trash back to the inbox
- Proactive OAuth token refresh before every batch (50-minute threshold vs 60-minute expiry)
- Live progress written to the database after each item, check status at any time
- Email notification with a summary when each task completes
- Celery retry on crash, tasks retry up to 3 times with a 60-second delay

---

## Requirements

- Python 3.10 or higher
- Redis (local or Docker)
- A Google Cloud project with the following APIs enabled:
  - Photos Library API
  - Google Drive API
  - Gmail API
- OAuth 2.0 credentials (`client_id` and `client_secret`) from [console.cloud.google.com](https://console.cloud.google.com)
- An SMTP email account for sending completion notifications

---

## Installation

Clone the repository and set up the environment using `uv`:

```bash
git clone https://github.com/codegeek004/codemos-hackathon.git
cd PhotosPurge

# Install uv (if you haven't already)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Sync dependencies (this creates .venv automatically)
uv sync
```

Apply database migrations:

```bash
python manage.py migrate
```

---

## Configuration

Copy the example environment file and fill in your values:

```bash
cp .env.example .env
```

```env
SECRET_KEY=your_django_secret_key

GOOGLE_CLIENT_ID=your_client_id
GOOGLE_CLIENT_SECRET=your_client_secret

CELERY_BROKER_URL=redis://localhost:6379/0
CELERY_RESULT_BACKEND=redis://localhost:6379/0

EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_HOST_USER=your_email@gmail.com
EMAIL_HOST_PASSWORD=your_app_password
```

`EMAIL_HOST_PASSWORD` should be a Gmail App Password, not your account password. Generate one at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).

---

## Running the Application

Start Redis (skip if already running):

```bash
docker run -d -p 6379:6379 redis
```

Start the Celery worker in one terminal:

```bash
celery -A codegeeks worker --loglevel=info
```

Start the Django development server in another:

```bash
python manage.py runsslserver
```

Open `https://127.0.0.1:8000` in your browser, sign in with Google, and start a migration or cleanup task from the dashboard.

---

## How It Works

### Photos migration (`photos/tasks.py`)

`migrate_all_photos_task` paginates through the source account using the Photos Library API, downloads each item with a Bearer token (the API requires authentication even for `baseUrl` downloads, so requests are made manually rather than through the service client), and uploads to the destination account. A 10-second sleep after each upload keeps the task within API rate limits. Progress is written to the database after each successful upload.

### Drive migration (`drive/tasks.py`)

`migrate_drive_task` paginates through the source Drive and rebuilds the folder hierarchy on the destination using a `folder_map` dictionary that maps source folder IDs to newly created destination IDs. Google Workspace files (Docs, Sheets, Slides) are exported to their Office equivalents before upload. If a file fails at any point, a `FailedMigration` record is written with the file ID, name, and reason and the task moves on to the next file. After a successful upload, the original is moved to Trash in the source account.

### Gmail cleanup (`gmailapp/tasks.py`)

`delete_emails_task` builds a Gmail API query using `category:<label>` (e.g. `category:promotions`), paginates through all matching messages, and moves each one to Trash using `messages().modify()`. `recover_emails_task` does the reverse, it fetches all messages with the `TRASH` label and removes it from each one. Both tasks check token validity before each page and write the refreshed token back to the `SocialToken` table if a refresh was needed.

---

## Project Structure

```
PhotosPurge/
├── codegeeks/
│   ├── settings.py          # Django + Celery configuration
│   ├── celery.py            # Celery app initialization
│   ├── urls.py
│   └── wsgi.py
│
├── gmailapp/
│   ├── models.py            # TaskStatus, RecoverStatus, CustomUser
│   ├── tasks.py             # delete_emails_task, recover_emails_task
│   ├── views.py
│   ├── utils.py             # retrieve_credentials_for_user
│   └── auth.py              # check_token_validity, refresh_google_token
│
├── photos/
│   ├── models.py            # MigrationStatus
│   ├── tasks.py             # migrate_all_photos_task
│   ├── views.py
│   └── utils.py             # get_photos_service, get_photos, upload_photo
│
├── drive/
│   ├── models.py            # MigrationStatus, FailedMigration
│   ├── tasks.py             # migrate_drive_task
│   ├── views.py
│   └── utils.py             # get_drive_service, get_drive_files,
│                            # download_all_formats, upload_all_formats,
│                            # create_drive_folder, trash_drive_file
│
├── manage.py
├── .env
└── requirements.txt
```

---

## Models

**gmailapp**

- `CustomUser` - extends Django's default user model, tracks `last_active`
- `TaskStatus` - records Gmail delete tasks: `task_id`, `user_id`, `status`, `result`, `deleted_count`
- `RecoverStatus` - records Gmail recovery tasks: `task_id`, `user_id`, `status`, `result`, `recover_count`

**photos**

- `MigrationStatus` - records photo migration tasks: `task_id`, `user_id`, `status`, `result`, `migrated_count`

**drive**

- `MigrationStatus` - records drive migration tasks: `task_id`, `user_id`, `status`, `result`, `migrated_count`, `total_count`
- `FailedMigration` - logs files that could not be migrated: `task_id`, `user_id`, `file_id`, `file_name`, `reason`

---

## Task Reference

| Task | App | Retries | Description |
|------|-----|---------|-------------|
| `migrate_all_photos_task` | `photos` | 3, 60s delay | Paginates source Photos library, downloads each item with Bearer auth, uploads to destination |
| `migrate_drive_task` | `drive` | 3, 60s delay | Paginates source Drive, recreates folder tree, downloads and uploads files, trashes source on success, logs failures |
| `delete_emails_task` | `gmailapp` | 3, no delay | Queries Gmail by category, paginates message list, moves each to Trash |
| `recover_emails_task` | `gmailapp` | 3, no delay| Fetches all Trash messages, removes TRASH label from each |

---

## Token Refresh Strategy

Google OAuth access tokens expire after 60 minutes. Migrations on large accounts can run for several hours, so proactive refresh is necessary.

For Photos and Drive tasks, credentials are refreshed immediately on task start and `token_refreshed_at` is recorded. Before every page of results, `refresh_if_older_than(credentials, minutes=50)` is called. If the token is older than 50 minutes it is refreshed and the timestamp is updated. This provides a 10-minute buffer before the 60-minute Google expiry.

Gmail tasks use a different path because credentials come from django-allauth's `SocialToken` table. `check_token_validity()` is called before each page, and if the token is expired it is refreshed via `creds.refresh(Request())` and written back to `SocialToken`.

---

## Known Limitations

- The Photos Library API does not support re-uploading original metadata (creation date, location) for migrated items. Uploaded photos appear with the upload date unless the original file's EXIF data carries that information.
- Google Workspace files (Docs, Sheets, Slides) are exported and re-uploaded as Office formats. Native Google format is not preserved.
- The 10-second sleep between photo uploads is necessary to avoid rate-limit errors but makes large migrations slow. Reducing it risks `429` responses from the API.
- There is no web UI for monitoring Celery worker health. Use `celery -A codegeeks inspect active` from the command line.

---

## Contributing

Bug reports and pull requests are welcome. For significant changes, open an issue first to discuss what you want to change.

### Git Workflow
We use a strict review-based branching strategy:
- All new features and bug fixes must target the **`review`** branch.
- The `main` branch is strictly locked for direct contributions and is updated solely by the repository administrator from the `review` branch.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Commit your changes (`git commit -m 'feat: add your feature'`)
4. Push to the branch (`git push origin feature/your-feature`)
5. Open a Pull Request targeting the **`review`** branch.

Please update tests where applicable.

---

## Acknowledgements

- [Django](https://www.djangoproject.com/)
- [Celery](https://docs.celeryq.dev/)
- [Redis](https://redis.io/)
- [django-allauth](https://github.com/pennersr/django-allauth)
- [Google Photos Library API](https://developers.google.com/photos)
- [Google Drive API](https://developers.google.com/drive)
- [Gmail API](https://developers.google.com/gmail/api)
- [google-auth](https://github.com/googleapis/google-auth-library-python)
- [Two Scoops of Django](https://www.feldroy.com/two-scoops-of-django) 
