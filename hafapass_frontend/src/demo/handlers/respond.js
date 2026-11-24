// Tiny response helpers for demo handlers. A handler returns `undefined`
// (not mine) or one of these objects; the adapter turns it into an Axios
// response, or a rejected request for status >= 400.
export const json = (data, status = 200) => ({ status, data })
export const created = data => json(data, 201)
export const notFound = (message = 'Not found in the demo preview.') => json({ error: message }, 404)
export const forbidden = (message = 'Not allowed in the demo preview.') => json({ error: message }, 403)
export const unprocessable = (message, errors) => json({ error: message, errors: errors || [message] }, 422)
