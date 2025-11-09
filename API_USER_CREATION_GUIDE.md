# User Creation API Documentation

This guide provides detailed instructions on how to programmatically create new users in the IPTV Panel system using its REST API.

---

## 1. Overview

The API provides a standard RESTful endpoint for creating users. It is authenticated using a secret bearer token and communicates using JSON.

- **HTTP Method:** `POST`
- **Endpoint:** `/api/users`
- **Authentication:** Bearer Token

---

## 2. Authentication

To use the API, you must provide a secret token in the `Authorization` header of your request. This token authenticates you as an administrator with the right to create users.

- **Header Name:** `Authorization`
- **Header Value:** `Bearer <YOUR_ADMIN_API_TOKEN>`

### Where to Find Your `ADMIN_API_TOKEN`

The `ADMIN_API_TOKEN` is configured in the `.env` file in the root directory of your project. You must set a secure, secret token for this variable.

```env
# .env file
...
ADMIN_API_TOKEN=your_secret_token_here
...
```

---

## 3. Request Details

### Endpoint
```
POST /api/users
```

### Headers
| Header          | Value                           |
|-----------------|---------------------------------|
| `Authorization` | `Bearer <YOUR_ADMIN_API_TOKEN>` |
| `Content-Type`  | `application/json`              |


### Request Body

The body of your `POST` request must be a JSON object containing the new user's details.

| Parameter         | Type    | Required? | Default        | Description                                                  |
|-------------------|---------|-----------|----------------|--------------------------------------------------------------|
| `username`        | string  | **Yes**   | -              | The username for the new account. Must be at least 3 characters. |
| `days`            | integer | **Yes**   | -              | The number of days the subscription will be valid from now.     |
| `max_connections` | integer | *Optional*| `1`            | The maximum number of simultaneous streams the user can have. |
| `password`        | string  | *Optional*| Auto-generated | The password for the new user. If omitted, a secure one is made. |
| `email`           | string  | *Optional*| `""`           | The user's email address.                                    |
| `notes`           | string  | *Optional*| `""`           | Any administrative notes you wish to add for this user.        |

---

## 4. Responses

### Success

- **Status Code:** `201 Created`
- **Body:** A JSON object containing the full details of the newly created user, including their system `user_id`, `token` for playlists, and `expires_at` date.

**Example Success Response:**
```json
{
  "user_id": 123,
  "username": "newuser",
  "password": "auto_generated_password",
  "token": "a_very_long_and_secure_user_token_for_playlists",
  "expires_at": "2025-12-09T14:00:00Z",
  "max_connections": 2,
  "email": "user@example.com",
  "m3u_url": "https://your.panel.com/playlist/a_very_long_and_secure_user_token_for_playlists.m3u8",
  "streaming_sync": {
    "success": true,
    "detail": "ok"
  },
  ...
}
```

### Errors

- **Status Code:** `401 Unauthorized` - If your `ADMIN_API_TOKEN` is missing or incorrect.
- **Status Code:** `400 Bad Request` - If required fields like `username` or `days` are missing, or if the data is invalid.
- **Status Code:** `409 Conflict` - If a user with the provided `username` already exists.

---

## 5. Complete `curl` Example

This example demonstrates how to create a new user named `api_user` with a 90-day subscription and 5 connections.

**Replace the following:**
- `<YOUR_PANEL_URL>` with your panel's full domain and protocol (e.g., `http://localhost:8080` or `https://panel.example.com`).
- `<YOUR_ADMIN_API_TOKEN>` with the secret token from your `.env` file.

```bash
curl -X POST 'https://<YOUR_PANEL_URL>/api/users' \
--header 'Authorization: Bearer <YOUR_ADMIN_API_TOKEN>' \
--header 'Content-Type: application/json' \
--data-raw 
{
    "username": "api_user",
    "days": 90,
    "max_connections": 5,
    "email": "api@example.com",
    "notes": "User created automatically via API for premium service"
}
```
