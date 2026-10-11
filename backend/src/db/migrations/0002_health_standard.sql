CREATE TABLE "endpoint_health_state" (
	"endpoint_id" uuid PRIMARY KEY NOT NULL,
	"checked_at" timestamp with time zone NOT NULL,
	"status" text NOT NULL,
	"version" text,
	"release_id" text,
	"output" text,
	"components" jsonb DEFAULT '[]'::jsonb NOT NULL
);
--> statement-breakpoint
ALTER TABLE "endpoints" ADD COLUMN "health_standard" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "health_check_results" ADD COLUMN "health_status" text;--> statement-breakpoint
ALTER TABLE "endpoint_health_state" ADD CONSTRAINT "endpoint_health_state_endpoint_id_endpoints_id_fk" FOREIGN KEY ("endpoint_id") REFERENCES "public"."endpoints"("id") ON DELETE cascade ON UPDATE no action;