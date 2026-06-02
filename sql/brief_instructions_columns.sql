-- Add writing instructions and sample book URL to briefs table
ALTER TABLE public.briefs
  ADD COLUMN IF NOT EXISTS writing_instructions text,
  ADD COLUMN IF NOT EXISTS sample_book_url      text;
