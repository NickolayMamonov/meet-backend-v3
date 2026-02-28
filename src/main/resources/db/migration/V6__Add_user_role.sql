-- V6__Add_user_role.sql

-- Добавляем поле role
ALTER TABLE users ADD COLUMN IF NOT EXISTS role VARCHAR(100);

-- Обновляем тестовых пользователей
UPDATE users SET role = 'Разработка' WHERE id = 1;
UPDATE users SET role = 'Разработка' WHERE id = 2;
UPDATE users SET role = 'Разработка' WHERE id = 3;
UPDATE users SET role = 'Дизайн' WHERE id = 4;