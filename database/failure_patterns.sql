-- Анализ торговли: что ПОЧТИ ВСЕГДА заканчивается провалом.
-- Только читает данные. Единственное, что создаётся: представление trade_facts (по одной строке на сделку,
-- то есть на твой вход вместе со всеми копиями). Ничего не удаляет и не меняет.
--
-- Как запускать: шаг 1 один раз, потом шаги 2 и 3 по отдельности (выдели нужный блок и запусти:
-- редактор показывает результат только последней команды).
--
-- Что считается провалом: сделка, которая закрылась хуже, чем win_ticks тиков чистой прибыли
-- (по умолчанию 10 тиков). Убыток, ноль и «высиженный безубыток» это всё провал.
-- Порог win_ticks, минимум сделок min_n и минимальная доля провалов min_fail можно менять
-- в первой строке каждого запроса.

-- ===================================================================
-- ШАГ 1. Представление (запустить один раз)
-- ===================================================================
create or replace view public.trade_facts
with (security_invoker = true) as
with g as (
  select group_no,
         min(opened_at)  as opened_at,
         max(closed_at)  as closed_at,
         min(direction)  as direction,
         min(instrument) as instrument,
         sum(cash)       as cash,
         avg(ticks)      as ticks,
         sum(max_qty)    as contracts
  from public.trade_summary
  where group_no is not null
    and not public.is_playback_account(account_name)
  group by group_no
  having bool_and(closed_at is not null)          -- только закрытые сделки
), base as (
  select g.*,
         extract(epoch from (closed_at - opened_at)) as dur_sec,
         (opened_at at time zone 'America/New_York') as et,
         ((opened_at at time zone 'America/Chicago') + interval '7 hours')::date as trading_day
  from g
), x as (
  select b.*,
         row_number() over (partition by trading_day order by opened_at) as day_no,
         lag(closed_at) over (order by opened_at) as prev_closed,
         lag(ticks)     over (order by opened_at) as prev_ticks,
         count(*) over (order by opened_at
                        range between interval '60 minutes' preceding and interval '1 second' preceding) as prev_hour_n
  from base b
)
select group_no, opened_at, closed_at, trading_day, direction,
       case when instrument like 'MNQ%' then 'MNQ' else 'NQ' end as instr,
       contracts, cash, ticks, dur_sec, prev_ticks,
       case when dur_sec < 60  then '1) до 1 мин'
            when dur_sec < 180 then '2) 1-3 мин'
            when dur_sec < 600 then '3) 3-10 мин'
            else '4) больше 10 мин' end as dur_bucket,
       case when extract(hour from et) * 60 + extract(minute from et) < 570 then '1) до открытия NY (до 9:30 ET)'
            when extract(hour from et) * 60 + extract(minute from et) < 600 then '2) открытие NY 9:30-10:00'
            when extract(hour from et) * 60 + extract(minute from et) < 690 then '3) 10:00-11:30'
            when extract(hour from et) * 60 + extract(minute from et) < 840 then '4) 11:30-14:00'
            when extract(hour from et) * 60 + extract(minute from et) < 930 then '5) 14:00-15:30'
            else '6) после 15:30' end as session,
       case extract(isodow from et)::int
            when 1 then '1) пн' when 2 then '2) вт' when 3 then '3) ср'
            when 4 then '4) чт' when 5 then '5) пт' else '6) вых' end as dow,
       case when day_no = 1 then '1) первая за день'
            when day_no <= 3 then '2) вторая-третья'
            when day_no <= 6 then '3) 4-6'
            else '4) седьмая и дальше' end as dayno_bucket,
       case when prev_closed is null then null
            when extract(epoch from (opened_at - prev_closed)) < 60  then '1) меньше 1 мин'
            when extract(epoch from (opened_at - prev_closed)) < 300 then '2) 1-5 мин'
            when extract(epoch from (opened_at - prev_closed)) < 900 then '3) 5-15 мин'
            else '4) больше 15 мин' end as gap_bucket,
       case when prev_hour_n <= 1 then '1) 0-1'
            when prev_hour_n <= 3 then '2) 2-3'
            else '3) 4 и больше' end as density_bucket
from x;

revoke all on public.trade_facts from anon;
grant select on public.trade_facts to authenticated;


-- ===================================================================
-- ШАГ 2. Проверка твоего наблюдения: сделки дольше нескольких минут
-- ===================================================================
with p as (select 10::numeric as win_ticks)
select dur_bucket                                                        as длительность,
       count(*)                                                          as сделок,
       count(*) filter (where ticks >= p.win_ticks)                      as побед,
       round(100.0 * count(*) filter (where ticks < p.win_ticks) / count(*)) as провал_проц,
       count(*) filter (where abs(ticks) <= 3)                           as около_нуля,
       round(avg(ticks), 1)                                              as ср_тиков,
       round(sum(cash))                                                  as итого_usd
from public.trade_facts, p
group by dur_bucket
order by dur_bucket;


-- ===================================================================
-- ШАГ 3. Комбинации, которые почти гарантируют провал
-- ===================================================================
-- Ищет одиночные признаки и пары признаков (длительность, направление, время дня относительно
-- открытия NY, день недели, номер сделки за день, пауза после прошлой сделки, итог прошлой сделки,
-- число сделок за прошлый час, инструмент и все твои теги).
-- Показывает только то, что одновременно:
--  * встречается не меньше min_n раз и проваливается не реже min_fail;
--  * держится в обеих половинах периода: не меньше min_half_n сделок в каждой и доля провалов
--    не ниже min_half_fail (так отсеиваются случайные совпадения);
--  * для пар: ни один из двух признаков сам по себе уже не даёт такого провала
--    (иначе пара ничего не добавляет к одиночному признаку).
-- нижняя_граница_проц: консервативная оценка доли провалов (интервал Вильсона, 95%).
-- Она учитывает, что у малой выборки «100%» ничего не значит.
-- Ищутся только пары: тройки признаков на сотнях сделок дали бы почти одни совпадения случайно.
with p as (select 10::numeric as win_ticks, 10 as min_n, 0.90::numeric as min_fail,
                  3 as min_half_n, 0.75::numeric as min_half_fail),
				  
--with p as (select 10::numeric as win_ticks, 8 as min_n, 0.65::numeric as min_fail,
--	3 as min_half_n, 0.50::numeric as min_half_fail),
f as (
  select t.*,
         (coalesce(t.ticks, 0) < p.win_ticks) as is_fail,
         case when t.prev_ticks is null then null
              when t.prev_ticks >= p.win_ticks then 'после победы'
              else 'после неудачи' end as prev_result
  from public.trade_facts t, p
),
mid as (select percentile_disc(0.5) within group (order by opened_at) as t from f),
feat as (
  select f.group_no, f.is_fail, f.opened_at, v.name, v.val
  from f cross join lateral (values
         ('длительность',   f.dur_bucket),
         ('направление',    f.direction),
         ('время дня',      f.session),
         ('день недели',    f.dow),
         ('номер за день',  f.dayno_bucket),
         ('пауза до входа', f.gap_bucket),
         ('прошлая сделка', f.prev_result),
         ('сделок за час',  f.density_bucket),
         ('инструмент',     f.instr)
       ) as v(name, val)
  where v.val is not null
  union all
  -- теги: те, что выбираются из набора взаимоисключающих (период графика, положение, тренд),
  -- собираются в один признак; остальные идут как «тег: имя = да»
  select f.group_no, f.is_fail, f.opened_at, g.fname, g.fval
  from f
  join public.trade_tags tt on tt.group_no = f.group_no
  join public.tags tg on tg.id = tt.tag_id
  cross join lateral (select
      case when tg.name in ('500T', '1000T', '2000T', '3000T') then 'график (тики)'
           when tg.name ~ '^tick_?[0-9]+%$'                    then 'tick_% (позиция)'
           when tg.name ~* '^5m_'                              then '5m относительно Mid'
           when tg.name ~* '^tick_(trend_(up|down)|no_trend)$'                      then 'tick тренд'
           when tg.name ~* '^tick_(above|below)_mid$'          then 'tick относительно Mid'
           else 'тег: ' || tg.name end as fname,
      case when tg.name in ('500T', '1000T', '2000T', '3000T')
             or tg.name ~ '^tick_?[0-9]+%$'
             or tg.name ~* '^5m_'
             or tg.name ~* '^tick_(trend_(up|down)|no_trend)$'
             or tg.name ~* '^tick_(above|below)_mid$'
           then tg.name else 'да' end as fval) g
),
combos as (
  select 1 as size, a.name || ' = ' || a.val as pattern,
         null::text as pa, null::text as pb, a.group_no, a.is_fail, a.opened_at
  from feat a
  union all
  select 2, a.name || ' = ' || a.val || '  И  ' || b.name || ' = ' || b.val,
         a.name || ' = ' || a.val, b.name || ' = ' || b.val, a.group_no, a.is_fail, a.opened_at
  from feat a
  join feat b on a.group_no = b.group_no and a.name < b.name
),
agg as (
  select size, pattern, pa, pb,
         count(*)                                                                  as n,
         count(*) filter (where is_fail)                                           as fails,
         count(*) filter (where opened_at <= (select t from mid))                  as n_old,
         count(*) filter (where opened_at <= (select t from mid) and is_fail)      as f_old,
         count(*) filter (where opened_at >  (select t from mid))                  as n_new,
         count(*) filter (where opened_at >  (select t from mid) and is_fail)      as f_new
  from combos
  group by size, pattern, pa, pb
),
scored as (
  select agg.*,
         fails::numeric / n as phat,
         ((fails::numeric / n) + 1.96 * 1.96 / (2 * n)
            - 1.96 * sqrt((fails::numeric / n) * (1 - fails::numeric / n) / n + 1.96 * 1.96 / (4.0 * n * n)))
           / (1 + 1.96 * 1.96 / n) as wilson_low
  from agg
),
strong_single as (
  select s.pattern from scored s, p
  where s.size = 1 and s.n >= p.min_n and s.phat >= p.min_fail
)
select s.size                                       as размер,
       s.pattern                                    as комбинация,
       s.n                                          as сделок,
       s.fails                                      as провалов,
       round(100 * s.phat)                          as провал_проц,
       round(100 * s.wilson_low)                    as нижняя_граница_проц,
       s.n_old                                      as старых,
       round(100.0 * s.f_old / nullif(s.n_old, 0))  as старые_проц,
       s.n_new                                      as новых,
       round(100.0 * s.f_new / nullif(s.n_new, 0))  as новые_проц
from scored s, p
where s.n >= p.min_n and s.phat >= p.min_fail
  and s.n_old >= p.min_half_n and s.n_new >= p.min_half_n
  and s.f_old::numeric / s.n_old >= p.min_half_fail
  and s.f_new::numeric / s.n_new >= p.min_half_fail
  and (s.size = 1
       or (s.pa not in (select pattern from strong_single)
           and s.pb not in (select pattern from strong_single)))
order by s.wilson_low desc, s.n desc
limit 60;
