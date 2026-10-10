CREATE TABLE "endpoint_version_secrets" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"endpoint_id" uuid NOT NULL,
	"encrypted_value" text NOT NULL,
	"iv" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "endpoint_version_secrets_endpoint_id_unique" UNIQUE("endpoint_id")
);
--> statement-breakpoint
CREATE TABLE "endpoint_version_state" (
	"endpoint_id" uuid PRIMARY KEY NOT NULL,
	"check_counter" integer DEFAULT 0 NOT NULL,
	"last_checked_at" timestamp with time zone,
	"last_is_success" boolean,
	"last_version" text,
	"last_failure_reason" text,
	"last_status_code" integer,
	"last_response_time_ms" integer
);
--> statement-breakpoint
CREATE TABLE "version_history" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"endpoint_id" uuid NOT NULL,
	"value" text NOT NULL,
	"first_seen_at" timestamp with time zone NOT NULL,
	"last_seen_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
ALTER TABLE "endpoints" ADD COLUMN "version_check" jsonb;--> statement-breakpoint
ALTER TABLE "notification_preferences" ADD COLUMN "notify_on_version_change" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "endpoint_version_secrets" ADD CONSTRAINT "endpoint_version_secrets_endpoint_id_endpoints_id_fk" FOREIGN KEY ("endpoint_id") REFERENCES "public"."endpoints"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "endpoint_version_state" ADD CONSTRAINT "endpoint_version_state_endpoint_id_endpoints_id_fk" FOREIGN KEY ("endpoint_id") REFERENCES "public"."endpoints"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "version_history" ADD CONSTRAINT "version_history_endpoint_id_endpoints_id_fk" FOREIGN KEY ("endpoint_id") REFERENCES "public"."endpoints"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "version_history_endpoint_first_seen_idx" ON "version_history" USING btree ("endpoint_id","first_seen_at");