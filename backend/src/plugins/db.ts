import fp from 'fastify-plugin';
import { db, type Database } from '../db/index.js';

declare module 'fastify' {
  interface FastifyInstance {
    db: Database;
  }
}

export default fp(async (fastify) => {
  fastify.decorate('db', db);
});
