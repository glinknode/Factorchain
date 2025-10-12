// simple structured logger, variadic to tolerate any call pattern
type Level = 'info' | 'warn' | 'error' | 'debug';

export function log(level: Level, ...parts: any[]) {
  const line = `[${level}] ${parts.map(p => (typeof p === 'string' ? p : JSON.stringify(p))).join(' ')}`;
  if (level === 'error') console.error(line);
  else if (level === 'warn') console.warn(line);
  else console.log(line);
}

// object-style API used in other modules
type LogFn = (...args: any[]) => void;
export const logger: { info: LogFn; warn: LogFn; error: LogFn; debug: LogFn } = {
  info: (...a) => log('info', ...a),
  warn: (...a) => log('warn', ...a),
  error: (...a) => log('error', ...a),
  debug: (...a) => log('debug', ...a),
};