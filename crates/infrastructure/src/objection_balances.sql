), first_events AS (
 SELECT DISTINCT ON (h.entity_id) h.entity_id, h.before_value
 FROM change_history h JOIN scoped s ON s.id=h.entity_id
 WHERE h.entity='incidents' ORDER BY h.entity_id,h.id
), categories(category) AS (VALUES ('All'),('Voucher Follow-up'),('MAP')),
events AS (
 SELECT h.entity_id,h.id,h.created_at,c.category,
   (CASE WHEN h.after_value->>'status' NOT IN ('Closed','Complied')
     AND (c.category='All' OR h.after_value->>'incident_type'=c.category) THEN 1 ELSE 0 END)
   -(CASE WHEN h.before_value->>'status' NOT IN ('Closed','Complied')
     AND (c.category='All' OR h.before_value->>'incident_type'=c.category) THEN 1 ELSE 0 END) AS delta
 FROM change_history h JOIN first_events f ON f.entity_id=h.entity_id AND f.before_value IS NULL
 CROSS JOIN categories c CROSS JOIN bounds b
 WHERE h.entity='incidents' AND h.created_at < (b.end_date+1)::timestamp AT TIME ZONE 'Asia/Kolkata'
), balances AS (
 SELECT c.category,
 coalesce(sum(e.delta) FILTER(WHERE e.created_at < b.start_date::timestamp AT TIME ZONE 'Asia/Kolkata'),0) AS opening,
 count(*) FILTER(WHERE e.delta=1 AND e.created_at >= b.start_date::timestamp AT TIME ZONE 'Asia/Kolkata') AS raised,
 count(*) FILTER(WHERE e.delta=-1 AND e.created_at >= b.start_date::timestamp AT TIME ZONE 'Asia/Kolkata') AS settled,
 coalesce(sum(e.delta),0) AS closing
 FROM categories c CROSS JOIN bounds b LEFT JOIN events e ON e.category=c.category GROUP BY c.category
), episodes AS (
 SELECT e.category,e.entity_id,max(e.created_at) FILTER(WHERE delta=1) AS opened
 FROM events e GROUP BY e.category,e.entity_id HAVING sum(delta)>0
), ages AS (
 SELECT e.category,
 count(*) FILTER(WHERE b.end_date-(e.opened AT TIME ZONE 'Asia/Kolkata')::date<90) AS under90,
 count(*) FILTER(WHERE b.end_date-(e.opened AT TIME ZONE 'Asia/Kolkata')::date>=90 AND b.end_date-(e.opened AT TIME ZONE 'Asia/Kolkata')::date<180) AS under180,
 count(*) FILTER(WHERE b.end_date-(e.opened AT TIME ZONE 'Asia/Kolkata')::date>=180) AS over180
 FROM episodes e CROSS JOIN bounds b GROUP BY e.category
)
SELECT to_jsonb(b)||jsonb_build_object('under90',coalesce(a.under90,0),'under180',coalesce(a.under180,0),'over180',coalesce(a.over180,0),
 'unknown',(SELECT count(*) FROM scoped s LEFT JOIN first_events f ON f.entity_id=s.id WHERE f.entity_id IS NULL OR f.before_value IS NOT NULL))
FROM balances b LEFT JOIN ages a USING(category) ORDER BY b.category
