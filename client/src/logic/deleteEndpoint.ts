export interface DeleteConfirmation {
  title: string;
  message: string;
}

/** Copy for the "delete endpoint" confirmation. The backend cascades the delete to everything below. */
export function deleteConfirmation(name: string): DeleteConfirmation {
  const label = name.trim() || 'this endpoint';
  return {
    title: `Delete "${label}"?`,
    message:
      "This permanently removes the endpoint along with its check history, incidents and uptime data. This can't be undone.",
  };
}

/**
 * A 404 means the endpoint is already gone (deleted from another device or the web), which is the
 * outcome the user asked for, so it is treated as a successful delete rather than an error.
 */
export function isAlreadyDeleted(status: number): boolean {
  return status === 404;
}
