use anyhow::Result;
use quick_xml::events::Event;

pub trait Parser {
    fn process(&mut self, ev: Event) -> Result<()>;
}
