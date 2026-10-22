// UI strings. The backend picks the language (setting, else the system's) and sends it in
// Snapshot.language; the dictionaries live in ./locales, English is the source of keys.
// On macOS the few texts about the system come from ./locales/en-mac.

import en, { type Key, type Messages } from "./locales/en";
import enMac from "./locales/en-mac";
import ru from "./locales/ru";
import uk from "./locales/uk";
import de from "./locales/de";
import fr from "./locales/fr";
import es from "./locales/es";
import ptBR from "./locales/pt-BR";
import it from "./locales/it";
import pl from "./locales/pl";
import tr from "./locales/tr";
import zhCN from "./locales/zh-CN";
import ja from "./locales/ja";
import ko from "./locales/ko";

/** Same codes and order as `SUPPORTED_LANGUAGES` in src-tauri/src/app/i18n.rs. */
export const LANGUAGES: { code: string; name: string; messages: Messages }[] = [
  { code: "en", name: "English", messages: en },
  { code: "de", name: "Deutsch", messages: de },
  { code: "es", name: "Español", messages: es },
  { code: "fr", name: "Français", messages: fr },
  { code: "it", name: "Italiano", messages: it },
  { code: "pl", name: "Polski", messages: pl },
  { code: "pt-BR", name: "Português (Brasil)", messages: ptBR },
  { code: "tr", name: "Türkçe", messages: tr },
  { code: "uk", name: "Українська", messages: uk },
  { code: "ru", name: "Русский", messages: ru },
  { code: "ja", name: "日本語", messages: ja },
  { code: "ko", name: "한국어", messages: ko },
  { code: "zh-CN", name: "简体中文", messages: zhCN },
];

let dict: Messages = en;
let mac = false;

/** `Snapshot.os`: `windows` or `macos`. */
export function setOs(os: string) {
  mac = os === "macos";
}

export function isMac(): boolean {
  return mac;
}

export function setLanguage(code: string) {
  const lang = LANGUAGES.find((l) => l.code === code) ?? LANGUAGES[0];
  dict = lang.messages;
  document.documentElement.lang = lang.code;
}

/** For keys built at run time, e.g. from an error code. */
export function hasKey(key: string): key is Key {
  return key in en;
}

export function t(key: Key, params: Record<string, string | number> = {}): string {
  return ((mac && enMac[key]) || dict[key]).replace(/\{(\w+)\}/g, (_, k) => String(params[k] ?? ""));
}
