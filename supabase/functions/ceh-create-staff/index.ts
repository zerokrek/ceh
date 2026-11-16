import { createClient } from "npm:@supabase/supabase-js@2";

const origin = "https://ceh.zerokrek.workers.dev";
const headers = {
  "Access-Control-Allow-Origin": origin,
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
  "Content-Type": "application/json",
};

const reply = (body, status = 200) => new Response(JSON.stringify(body), { headers, status });
const url = Deno.env.get("SUPABASE_URL");
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const authOptions = { auth: { persistSession: false, autoRefreshToken: false } };

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response(null, { headers, status: 204 });
  if (request.method !== "POST") return reply({ error: "Недопустимый метод" }, 405);
  if (!url || !serviceKey) return reply({ error: "Функция не настроена" }, 503);

  const token = request.headers.get("Authorization")?.match(/^Bearer (\S+)$/i)?.[1];
  if (!token) return reply({ error: "Войди в ЦЕХ" }, 401);

  const server = createClient(url, serviceKey, authOptions);
  const { data: { user }, error: authError } = await server.auth.getUser(token);
  if (authError || !user) return reply({ error: "Сессия недействительна" }, 401);

  const { data: profile, error: profileError } = await server.from("ceh_profiles")
    .select("role").eq("id", user.id).maybeSingle();
  if (profileError) return reply({ error: "Не удалось проверить права" }, 503);
  if (profile?.role !== "admin") return reply({ error: "Требуются права администратора" }, 403);

  const body = await request.json().catch(() => null);
  const login = body?.login;
  if (typeof login !== "string" || !/^konditer[1-4]$/.test(login)) {
    return reply({ error: "Выбери кондитера с 1 по 4" }, 400);
  }

  // The employee does not have a warehouse profile until activation is implemented.
  // This endpoint is staged in the prototype branch and must ship with activation.
  const suffix = Array.from(crypto.getRandomValues(new Uint8Array(18)),
    (byte) => byte.toString(16).padStart(2, "0")).join("");
  const password = "Ceh!" + suffix;
  const { error } = await server.auth.admin.createUser({
    email: login + "@ceh.invalid",
    email_confirm: true,
    password,
    app_metadata: { ceh_login: login, ceh_pending_activation: true },
  });

  if (error?.code === "email_exists" || error?.code === "user_already_exists") {
    return reply({ error: "Учётная запись уже существует" }, 409);
  }
  if (error) return reply({ error: "Не удалось создать учётную запись" }, 502);
  return reply({ login, temporaryPassword: password }, 201);
});