select session as время_дня,
       count(*) as сделок,
       count(*) filter (where ticks < 10) as провалов,
       round(100.0 * count(*) filter (where ticks < 10) / count(*)) as провал_проц,
       round(avg(ticks), 1) as ср_тиков,
       round(sum(cash)) as итого_usd
from public.trade_facts
group by session
order by session;


select extract(hour from (opened_at at time zone 'America/New_York'))::int as час_ET,
       count(*) as сделок,
       count(*) filter (where ticks < 10) as провалов,
       round(avg(ticks), 1) as ср_тиков,
       round(sum(cash)) as итого_usd
from public.trade_facts
group by 1
order by 1;

select session as время_дня, dur_bucket as длительность,
       count(*) as сделок,
       round(avg(ticks), 1) as ср_тиков,
       round(sum(cash)) as итого_usd
from public.trade_facts
group by session, dur_bucket
order by session, dur_bucket;