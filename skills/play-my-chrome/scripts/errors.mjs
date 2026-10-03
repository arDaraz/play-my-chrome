export class SkillError extends Error {
  constructor(message, exitCode = 1) {
    super(message);
    this.exitCode = exitCode;
  }
}

export async function bounded(operation, milliseconds) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new SkillError('Operation timed out. Run connect again when Chrome is ready.', 124)), milliseconds);
  });
  try {
    return await Promise.race([operation, deadline]);
  } finally {
    clearTimeout(timer);
  }
}
